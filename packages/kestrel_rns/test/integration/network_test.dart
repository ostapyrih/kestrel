@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import '../support/it_support.dart';
import '../support/python_peer.dart';

/// Announce / path / proof / reconnect behaviour against the Python
/// reference implementation (`tools/it/rns_peer.py`).
void main() {
  if (findPython() == null) {
    test('python reference not available', () {}, skip: 'no tools/.venv');
    return;
  }

  late PythonPeer peer;
  late Reticulum dart;

  group('against python RNS 1.6.1', () {
    setUp(() async {
      peer = await PythonPeer.start();
      dart = await node(peer.port);
    });
    tearDown(() async {
      await dart.stop();
      await peer.stop();
    });

    test('receives and validates a python announce, learns path + identity',
        () async {
      final got = dart.announces.first.timeout(const Duration(seconds: 10));
      peer.send({'cmd': 'announce', 'app_data': '6b657374'});
      final a = await got;
      expect(toHex(a.destinationHash), peer.destHash);
      expect(a.hops, 1);
      expect(utf8.decode(a.appData), 'kest');
      expect(dart.transport.hasPath(a.destinationHash), isTrue);
      expect(toHex(dart.transport.recallIdentity(a.destinationHash)!.publicKey),
          peer.ready['public_key']);
      expect(dart.transport.hopsTo(a.destinationHash), 1);
    });

    test('path request is answered by the python peer', () async {
      final h = fromHex(peer.destHash);
      expect(dart.transport.hasPath(h), isFalse);
      final ok = await dart.awaitPath(h, timeout: const Duration(seconds: 10));
      expect(ok, isTrue);
      expect(dart.transport.hopsTo(h), 1);
    });

    test('stamped path request is accepted too', () async {
      final stamped = await node(
        peer.port,
        config: const TransportConfig(
          stampAnnounces: false,
          stampPathRequests: true,
          pathRequestStampValue: 8,
        ),
      );
      addTearDown(stamped.stop);
      final ok = await stamped.awaitPath(
        fromHex(peer.destHash),
        timeout: const Duration(seconds: 10),
      );
      expect(ok, isTrue);
    });

    test('python receives dart announce and answers dart path request',
        () async {
      final id = await Identity.generate();
      final d = await dart.createDestination(id, 'kestrel', ['it', 'dart']);
      final recv = peer.waitFor('announce_received',
          where: (m) => m['dest_hash'] == toHex(d.hash));
      expect(await dart.announce(d, appData: utf8.encode('hi')), isTrue);
      final m = await recv;
      expect(m['identity'], toHex(id.hash));
      expect(m['app_data'], toHex(utf8.encode('hi')));

      // python asks for a path -> dart answers with a PATH_RESPONSE announce
      final id2 = await Identity.generate();
      final d2 = await dart.createDestination(id2, 'kestrel', ['it', 'dart2']);
      peer.send({'cmd': 'request_path', 'dest_hash': toHex(d2.hash)});
      final pr = await peer.waitFor('announce_received',
          where: (m) => m['dest_hash'] == toHex(d2.hash));
      expect(pr['path_response'], isTrue);
    });

    test('ratchet-enabled destination: python encrypts with the ratchet',
        () async {
      final id = await Identity.generate();
      final d = await dart.createDestination(
        id,
        'kestrel',
        ['it', 'ratchet'],
        ratchets: true,
      );
      d.proofStrategy = ProofStrategy.all;
      final got = Completer<String>();
      d.onPacket = (data, p) => got.complete(toHex(data));
      final recv = peer.waitFor('announce_received',
          where: (m) => m['dest_hash'] == toHex(d.hash));
      await dart.announce(d);
      await recv;
      peer.send({
        'cmd': 'send_packet',
        'dest_hash': toHex(d.hash),
        'aspects': ['kestrel', 'it', 'ratchet'],
        'data': '010203',
      });
      expect(await got.future.timeout(const Duration(seconds: 10)), '010203');
      final del = await peer.waitFor('packet_delivered');
      expect(del['data'], '010203'); // implicit proof validated by python
    });

    test('SINGLE packet to python is proved (receipt delivered)', () async {
      final h = fromHex(peer.destHash);
      await dart.awaitPath(h);
      final out = dart.recallDestination(h, 'kestrel', ['it', 'peer'])!;
      final pk = peer.waitFor('packet');
      final receipt = await dart.send(out, [1, 2, 3, 4]);
      expect(receipt, isNotNull);
      expect((await pk)['data'], '01020304');
      final r = await receipt!.done.timeout(const Duration(seconds: 10));
      expect(r.status, ReceiptStatus.delivered);
    });

    test('announce with real PoW stamp: python validates the stamp', () async {
      // fresh python peer that requires only value 8 for valid stamps
      final p2 = await PythonPeer.start(destCost: 8);
      final d2 = await node(
        p2.port,
        config: const TransportConfig(
          stampAnnounces: true,
          announceStampValue: 9,
          stampPathRequests: false,
        ),
      );
      addTearDown(() async {
        await d2.stop();
        await p2.stop();
      });
      final id = await Identity.generate();
      final d = await d2.createDestination(id, 'kestrel', ['it', 'stamped']);
      final recv = p2.waitFor('announce_received',
          where: (m) => m['dest_hash'] == toHex(d.hash));
      expect(await d2.announce(d, appData: utf8.encode('stamped')), isTrue);
      final m = await recv;
      // python strips the ext payload only when the stamp is valid
      expect(m['app_data'], toHex(utf8.encode('stamped')));
      expect(d.stampValue, greaterThanOrEqualTo(9));
    });

    test('python announce with stamp is validated by dart', () async {
      final p2 = await PythonPeer.start(stamps: true);
      final d2 = await node(
        p2.port,
        config: const TransportConfig(
          stampAnnounces: false,
          stampPathRequests: false,
          requiredAnnounceStampCost: 20,
        ),
      );
      addTearDown(() async {
        await d2.stop();
        await p2.stop();
      });
      final got = d2.announces.first;
      p2.send({'cmd': 'announce', 'app_data': '6162'});
      final a = await got.timeout(const Duration(seconds: 120));
      expect(a.announce.stamp, isNotNull);
      expect(a.announce.stampValue, greaterThanOrEqualTo(23.5));
      expect(a.announce.linkCost, isNotNull);
      expect(a.appData, Uint8List.fromList([0x61, 0x62]));
    }, timeout: const Timeout(Duration(seconds: 170)));

    test('reconnects after the server restarts', () async {
      final port = peer.port;
      final states = <InterfaceState>[];
      final sub = dart.interfaceEvents.listen((e) => states.add(e.state));
      await peer.stop();
      await until(() => !dart.interfaces.first.online);
      peer = await PythonPeer.start(port: port);
      await until(() => dart.interfaces.first.online,
          timeout: const Duration(seconds: 20));
      expect(states, contains(InterfaceState.offline));
      // still functional: path request works again
      final ok = await dart.awaitPath(
        fromHex(peer.destHash),
        timeout: const Duration(seconds: 10),
      );
      expect(ok, isTrue);
      await sub.cancel();
    });
  });
}
