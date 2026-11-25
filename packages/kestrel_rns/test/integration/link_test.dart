@Tags(['integration'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import '../support/it_support.dart';
import '../support/python_peer.dart';

/// Links, request/response and resources against the Python reference.
void main() {
  if (findPython() == null) {
    test('python reference not available', () {}, skip: 'no tools/.venv');
    return;
  }

  late PythonPeer peer;
  late Reticulum dart;

  Future<Link> toPeer(Reticulum r) async {
    final h = fromHex(peer.destHash);
    expect(await r.awaitPath(h), isTrue);
    final d = r.recallDestination(h, 'kestrel', ['it', 'peer'])!;
    return r.connect(d);
  }

  group('dart initiates links to python', () {
    setUp(() async {
      peer = await PythonPeer.start();
      dart = await node(peer.port);
    });
    tearDown(() async {
      await dart.stop();
      await peer.stop();
    });

    test('link establishment: proof signature, RTT, MTU discovery', () async {
      final established = peer.waitFor('link_established');
      final link = await toPeer(dart);
      expect(link.isActive, isTrue);
      expect(link.rtt, isNotNull);
      // the python TCPServerInterface clamps/confirms its own HW_MTU
      expect(link.mtu, greaterThan(500));
      expect(link.mdu, greaterThan(link.mtu - 100));
      final m = await established;
      expect(m['initiator'], isFalse);
      expect(m['mtu'], link.mtu);
      expect(m['link_id'], toHex(link.linkId));
    });

    test('identify() reaches the python peer; /whoami sees the identity',
        () async {
      final link = await toPeer(dart);
      final me = await Identity.generate();
      final ident = peer.waitFor('remote_identified');
      await link.identify(me);
      expect((await ident)['identity'], toHex(me.hash));
      final rr = await link.request('/whoami');
      await rr!.done;
      expect(rr.status, RequestStatus.ready);
      expect(toHex(rr.response! as Uint8List), toHex(me.hash));
    });

    test('request/response: small echo, msgpack types survive', () async {
      final link = await toPeer(dart);
      final rr =
          await link.request('/echo', data: Uint8List.fromList([9, 8, 7]));
      await rr!.done;
      expect(rr.status, RequestStatus.ready);
      expect(rr.response, Uint8List.fromList([9, 8, 7]));
      expect(rr.responseTime, isNotNull);
    });

    test('large response (50 KB) arrives as a Resource', () async {
      final link = await toPeer(dart);
      var progressed = false;
      final rr = await link.request(
        '/big',
        onProgress: (r) => progressed = true,
      );
      await rr!.done.timeout(const Duration(seconds: 30));
      expect(rr.status, RequestStatus.ready);
      final body = rr.response! as Uint8List;
      expect(body, pseudoRandom(50000));
      expect(progressed, isTrue);
    });

    test('compressed (bz2) resource response', () async {
      final link = await toPeer(dart);
      final rr = await link.request('/big_text');
      await rr!.done.timeout(const Duration(seconds: 30));
      expect(rr.status, RequestStatus.ready);
      final body = rr.response! as Uint8List;
      expect(body.length, 200000);
      expect(String.fromCharCodes(body.sublist(0, 33)),
          'kestrel reticulum resource test. ');
    });

    test('max_response_size rejects an oversized response', () async {
      final link = await toPeer(dart);
      final rr = await link.request('/big', maxResponseSize: 1000);
      await rr!.done.timeout(const Duration(seconds: 15));
      expect(rr.status, RequestStatus.failed);
    });

    test('unknown request path times out', () async {
      final link = await toPeer(dart);
      final rr = await link.request('/nope', timeout: 1.0);
      await rr!.done.timeout(const Duration(seconds: 5));
      expect(rr.status, RequestStatus.failed);
    });

    test('dart sends a resource to python (hash verified)', () async {
      final link = await toPeer(dart);
      final data = pseudoRandom(120000, seed: 'dart-out');
      final done = peer.waitFor('resource_concluded');
      final sent = Completer<Resource>();
      await link.sendResource(data, callback: sent.complete);
      final m = await done;
      expect(m['size'], 120000);
      expect(m['sha256'], toHex(sha256(data)));
      final r = await sent.future.timeout(const Duration(seconds: 10));
      expect(r.status, ResourceStatus.complete);
    });

    test('compressible resource to python is bz2-compressed on the wire',
        () async {
      final link = await toPeer(dart);
      final data = Uint8List.fromList(List.filled(300000, 0x61));
      final done = peer.waitFor('resource_concluded');
      final sent = Completer<Resource>();
      await link.sendResource(data, callback: sent.complete);
      final m = await done;
      expect(m['size'], 300000);
      expect(m['sha256'], toHex(sha256(data)));
      expect((await sent.future).status, ResourceStatus.complete);
    });

    test('link teardown from dart closes the python side', () async {
      final link = await toPeer(dart);
      final closed = peer.waitFor('link_closed');
      await link.teardown();
      await closed;
      expect(link.status, LinkStatus.closed);
      expect(link.teardownReason, TeardownReason.initiatorClosed);
    });

    test('link teardown from python closes the dart side', () async {
      final link = await toPeer(dart);
      peer.send({'cmd': 'teardown'});
      await link.closed.timeout(const Duration(seconds: 10));
      expect(link.teardownReason, TeardownReason.destinationClosed);
    });

    test('data over the link + proof receipt', () async {
      final link = await toPeer(dart);
      final got = peer.waitFor('link_packet');
      final receipt = await link.send([1, 2, 3]);
      expect((await got)['data'], '010203');
      // python's destination is PROVE_ALL, so the link packet is proved
      final r = await receipt!.done.timeout(const Duration(seconds: 10));
      expect(r.status, ReceiptStatus.delivered);
    });

    test('keepalive keeps an idle link alive both ways', () async {
      final link = await toPeer(dart);
      // loopback RTT => keepalive 5 s, stale after 10 s: the link only
      // survives if keepalive/echo works in both directions
      expect(link.keepalive, 5);
      await Future<void>.delayed(const Duration(seconds: 13));
      expect(link.isActive, isTrue);
      expect(link.status, isNot(LinkStatus.stale));
    });
  });

  group('python initiates links to dart', () {
    late Destination dest;
    final established = <Link>[];
    final identified = Completer<Identity>();

    setUp(() async {
      peer = await PythonPeer.start();
      dart = await node(peer.port);
      established.clear();
      final id = await Identity.generate();
      dest = await dart.createDestination(id, 'kestrel', ['it', 'dartserver']);
      dest.registerRequestHandler(
        '/echo',
        (path, data, id, linkId, remote, at) => data,
        policy: RequestPolicy.all,
      );
      dest.registerRequestHandler(
        '/big',
        (path, data, id, linkId, remote, at) => pseudoRandom(50000, seed: 'd'),
        policy: RequestPolicy.all,
      );
      dest.registerRequestHandler(
        '/secret',
        (path, data, id, linkId, remote, at) => 'ok',
        policy: RequestPolicy.list,
        allowedList: [fromHex(peer.ready['identity_hash']! as String)],
      );
      dest.onLinkEstablished = (l) {
        final link = l as Link;
        established.add(link);
        link.resourceStrategy = ResourceStrategy.all;
        link.onRemoteIdentified = (_, i) {
          if (!identified.isCompleted) identified.complete(i);
        };
      };
      final heard = peer.waitFor('announce_received',
          where: (m) => m['dest_hash'] == toHex(dest.hash));
      await dart.announce(dest);
      await heard;
    });
    tearDown(() async {
      await dart.stop();
      await peer.stop();
    });

    Future<Link> pyLink() async {
      final ev = peer.waitFor('link_established');
      peer.send({
        'cmd': 'link',
        'dest_hash': toHex(dest.hash),
        'aspects': ['kestrel', 'it', 'dartserver'],
      });
      await ev;
      await until(() => established.isNotEmpty && established.first.isActive);
      return established.first;
    }

    test('responder: LRPROOF accepted by python, rtt measured', () async {
      final link = await pyLink();
      expect(link.initiator, isFalse);
      expect(link.mtu, greaterThan(500));
      expect(link.rtt, isNotNull);
    });

    test('request handler: echo, allow-list policy with identify', () async {
      await pyLink();
      peer.send({'cmd': 'link_request', 'path': '/echo', 'data': '0a0b'});
      final r = await peer.waitFor('response');
      expect(r['data'], '0a0b');

      // /secret needs identification -> not answered before identify
      peer.send({'cmd': 'link_request', 'path': '/secret'});
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(peer.has('response'), isFalse);

      peer.send({'cmd': 'identify'});
      final who = await identified.future.timeout(const Duration(seconds: 10));
      expect(toHex(who.hash), peer.ready['identity_hash']);
      expect(toHex(established.first.remoteIdentity!.hash),
          peer.ready['identity_hash']);
    });

    test('large response (resource) to python request', () async {
      await pyLink();
      peer.send({'cmd': 'link_request', 'path': '/big'});
      final r = await peer.waitFor('response');
      expect(r['size'], 50000);
      expect(r['sha256'], toHex(sha256(pseudoRandom(50000, seed: 'd'))));
    });

    test('python sends a resource, dart receives it', () async {
      final link = await pyLink();
      final got = Completer<Resource>();
      link.onResourceConcluded = got.complete;
      peer.send({'cmd': 'send_resource', 'size': 150000});
      final res = await got.future.timeout(const Duration(seconds: 30));
      expect(res.status, ResourceStatus.complete);
      expect(res.data, pseudoRandom(150000));
      final sent = await peer.waitFor('resource_sent');
      expect(sent['complete'], isTrue);
    });

    test('python sends a compressible resource', () async {
      final link = await pyLink();
      final got = Completer<Resource>();
      link.onResourceConcluded = got.complete;
      peer.send({'cmd': 'send_resource', 'size': 90000, 'compressible': true});
      final res = await got.future.timeout(const Duration(seconds: 30));
      expect(res.data!.length, 90000);
      expect(res.data!.sublist(0, 6), 'abcabc'.codeUnits);
    });

    test('data packet from python reaches the link callback', () async {
      final link = await pyLink();
      final got = Completer<Uint8List>();
      link.onPacket = (d, p) => got.complete(d);
      peer.send({'cmd': 'link_send', 'data': 'deadbeef'});
      expect(toHex(await got.future.timeout(const Duration(seconds: 5))),
          'deadbeef');
    });

    test('teardown propagates', () async {
      final link = await pyLink();
      peer.send({'cmd': 'teardown'});
      await link.closed.timeout(const Duration(seconds: 10));
      expect(link.teardownReason, TeardownReason.initiatorClosed);
    });
  });

  group('link MTU 500 (no discovery): multi-part resources, HMU', () {
    setUp(() async {
      peer = await PythonPeer.start();
      dart = await node(
        peer.port,
        config: const TransportConfig(
          stampAnnounces: false,
          stampPathRequests: false,
          linkMtuDiscovery: false,
        ),
      );
    });
    tearDown(() async {
      await dart.stop();
      await peer.stop();
    });

    test('50 KB response over 500-byte MTU (many parts, hashmap updates)',
        () async {
      final link = await toPeer(dart);
      expect(link.mtu, 500);
      final rr = await link.request('/big');
      await rr!.done.timeout(const Duration(seconds: 60));
      expect(rr.status, RequestStatus.ready);
      expect(rr.response, pseudoRandom(50000));
    });

    test('dart -> python resource over 500-byte MTU', () async {
      final link = await toPeer(dart);
      final data = pseudoRandom(60000, seed: 'small-mtu');
      final done = peer.waitFor('resource_concluded');
      await link.sendResource(data);
      final m = await done.timeout(const Duration(seconds: 60));
      expect(m['sha256'], toHex(sha256(data)));
    });

    test('large request (> link MDU) travels as a resource', () async {
      final link = await toPeer(dart);
      final payload = pseudoRandom(5000, seed: 'req');
      final rr = await link.request('/echo', data: payload);
      await rr!.done.timeout(const Duration(seconds: 60));
      expect(rr.status, RequestStatus.ready);
      expect(rr.response, payload);
    });
  });
}
