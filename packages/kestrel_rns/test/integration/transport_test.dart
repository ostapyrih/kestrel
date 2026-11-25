@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import '../support/it_support.dart';
import '../support/python_peer.dart';

/// Two Dart nodes talking through a python node with `enable_transport = Yes`
/// (announce rebroadcast, HEADER_2 routing, link table forwarding).
void main() {
  if (findPython() == null) {
    test('python reference not available', () {}, skip: 'no tools/.venv');
    return;
  }

  late PythonPeer hub;
  late Reticulum a;
  late Reticulum b;
  late Destination destA;

  setUp(() async {
    hub = await PythonPeer.start(transport: true);
    a = await node(hub.port);
    b = await node(hub.port);
    destA = await a.createDestination(
      await Identity.generate(),
      'kestrel',
      ['it', 'a'],
    );
    destA.registerRequestHandler(
      '/echo',
      (path, data, id, linkId, remote, at) => data,
      policy: RequestPolicy.all,
    );
    destA.registerRequestHandler(
      '/big',
      (path, data, id, linkId, remote, at) => pseudoRandom(40000, seed: 'a'),
      policy: RequestPolicy.all,
    );
    destA.proofStrategy = ProofStrategy.all;
  });
  tearDown(() async {
    await a.stop();
    await b.stop();
    await hub.stop();
  });

  test('announce is rebroadcast by the transport: B learns a 2-hop path',
      () async {
    final got = b.announces
        .firstWhere((e) => toHex(e.destinationHash) == toHex(destA.hash))
        .timeout(const Duration(seconds: 15));
    await a.announce(destA, appData: utf8.encode('from-a'));
    final e = await got;
    expect(e.hops, 2);
    expect(utf8.decode(e.appData), 'from-a');
    final entry = b.transport.pathTo(destA.hash)!;
    expect(entry.hops, 2);
    // next hop is the python transport instance, not A itself
    expect(toHex(entry.nextHop), isNot(toHex(destA.hash)));
    expect(entry.nextHop.length, 16);
  });

  test('path request answered from the transport path table (HEADER_2)',
      () async {
    final heard = hub.waitFor('announce_received',
        where: (m) => m['dest_hash'] == toHex(destA.hash));
    await a.announce(destA);
    await heard;
    // B connected before the announce, so ask explicitly after forgetting
    b.transport.expirePath(destA.hash);
    final ok = await b.awaitPath(destA.hash);
    expect(ok, isTrue);
    expect(b.transport.hopsTo(destA.hash), 2);
  });

  test('B links to A via the transport: request, resource response, proofs',
      () async {
    final heard = b.announces
        .firstWhere((e) => toHex(e.destinationHash) == toHex(destA.hash));
    await a.announce(destA);
    await heard.timeout(const Duration(seconds: 15));

    final outA = b.recallDestination(destA.hash, 'kestrel', ['it', 'a'])!;
    final inbound = Completer<Link>();
    destA.onLinkEstablished = (l) => inbound.complete(l as Link);
    final link = await b.connect(outA);
    expect(link.isActive, isTrue);
    final aLink = await inbound.future.timeout(const Duration(seconds: 5));
    await until(() => aLink.isActive);

    final rr = await link.request('/echo', data: 'hello');
    await rr!.done;
    expect(rr.response, 'hello');

    final big = await link.request('/big');
    await big!.done.timeout(const Duration(seconds: 30));
    expect(big.response, pseudoRandom(40000, seed: 'a'));

    // packet proof routed back through the transport
    final got = Completer<Uint8List>();
    aLink.onPacket = (d, p) => got.complete(d);
    final receipt = await link.send([5, 6, 7]);
    expect(await got.future.timeout(const Duration(seconds: 5)),
        Uint8List.fromList([5, 6, 7]));
    expect((await receipt!.done.timeout(const Duration(seconds: 10))).status,
        ReceiptStatus.delivered);

    // and a resource B -> A
    final recv = Completer<Resource>();
    aLink.resourceStrategy = ResourceStrategy.all;
    aLink.onResourceConcluded = recv.complete;
    final data = pseudoRandom(70000, seed: 'b');
    await link.sendResource(data);
    final res = await recv.future.timeout(const Duration(seconds: 30));
    expect(res.data, data);

    await link.teardown();
    await aLink.closed.timeout(const Duration(seconds: 10));
  });

  test('single packet B -> A via HEADER_2 is delivered and proved', () async {
    final heard = b.announces
        .firstWhere((e) => toHex(e.destinationHash) == toHex(destA.hash));
    await a.announce(destA);
    await heard.timeout(const Duration(seconds: 15));
    final got = Completer<Uint8List>();
    destA.onPacket = (d, p) => got.complete(d);
    final outA = b.recallDestination(destA.hash, 'kestrel', ['it', 'a'])!;
    final receipt = await b.send(outA, [42]);
    expect(await got.future.timeout(const Duration(seconds: 10)),
        Uint8List.fromList([42]));
    expect((await receipt!.done.timeout(const Duration(seconds: 10))).status,
        ReceiptStatus.delivered);
  });
}
