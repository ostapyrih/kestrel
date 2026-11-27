@Tags(['integration'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import '../support/it_support.dart';
import '../support/python_peer.dart';

/// Propagation (offline mail) against a real Python LXMF 1.3.1 propagation
/// node and client, all on loopback TCP (`tools/it/lxmf_peer.py`).
void main() {
  if (findPython() == null) {
    test('python reference not available', () {}, skip: 'no tools/.venv');
    return;
  }

  const fast = LxmRouterConfig(
    processInterval: Duration(milliseconds: 200),
    deliveryRetryWait: Duration(seconds: 2),
    pathRequestWait: Duration(seconds: 2),
    autoSync: false,
    propagationSyncInterval: null,
  );

  late PythonPeer pn; // the propagation node (also a transport node)
  PythonPeer? py; // a python LXMF client behind the node
  late Reticulum dart;
  late Identity me;
  late LxmRouter router;
  final extras = <Future<void> Function()>[];

  Future<void> start({
    List<String> nodeArgs = const [],
    LxmRouterConfig config = fast,
    bool withClient = true,
  }) async {
    pn = await PythonPeer.startLxmfRaw(
      transport: true,
      extraArgs: [
        '--name',
        'PN',
        '--propagation',
        '--pn-name',
        'Test PN',
        ...nodeArgs,
      ],
    );
    if (withClient) {
      py = await PythonPeer.startLxmfRaw(
        extraArgs: ['--name', 'Py Client', '--connect', '${pn.port}'],
      );
    }
    dart = await node(pn.port);
    me = await Identity.generate();
    router =
        await LxmRouter.start(dart, me, displayName: 'Dart', config: config);
    await router.announce();
    pn.send({'cmd': 'announce_node'});
    await until(() => router.propagationNodes.isNotEmpty);
    if (withClient) {
      py!.send({'cmd': 'set_node', 'hash': pn.ready['pn_hash']});
      pn.send({'cmd': 'announce_node'});
      await py!.waitFor('pn_announce');
      py!.send({'cmd': 'announce'});
      await until(() => router.peer(fromHex(py!.destHash)) != null);
      // Python learns dart's key from the announce (or asks for the path
      // when it sends).
      await router.announce();
      py!.send({'cmd': 'ensure', 'dest_hash': toHex(router.address)});
      final k = await py!.waitFor('known');
      expect(k['ok'], isTrue, reason: 'python could not learn dart');
    }
  }

  tearDown(() async {
    for (final f in extras) {
      await f();
    }
    extras.clear();
    await router.stop();
    await dart.stop();
    await py?.stop();
    py = null;
    await pn.stop();
  });

  Future<void> pySend(
    String content, {
    String method = 'propagated',
    double? ts,
    int? size,
  }) async {
    py!.send({
      'cmd': 'send',
      'dest_hash': toHex(router.address),
      if (size == null) 'content': content else 'size': size,
      'method': method,
      if (ts != null) 'timestamp': ts,
    });
    await py!.waitFor('queued');
  }

  /// Python syncs its inbox; the node may still be validating a freshly
  /// uploaded resource, so retry until [event] shows up.
  Future<Map<String, Object?>> pySyncUntilReceived() async {
    for (var i = 0; i < 6; i++) {
      py!.send({'cmd': 'sync'});
      await py!.waitFor('sync_done');
      if (py!.has('received')) break;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return py!.waitFor('received');
  }

  test('discovery: node announce decoded (name, limits, cost, hops)', () async {
    await start(withClient: false);
    final n = router.propagationNodes.single;
    expect(toHex(n.hash), pn.ready['pn_hash']);
    expect(n.name, 'Test PN');
    expect(n.enabled, isTrue);
    expect(n.data.transferLimitKb, 256);
    expect(n.data.syncLimitKb, 256 * 40);
    expect(n.data.stampCost, 13);
    expect(n.data.stampCostFlexibility, 3);
    expect(n.hops, 1);
    expect(router.activeNode, n.hash);
  });

  test('dart -> python via node: stamped upload, python retrieves', () async {
    await start();
    final o = await router.send(
      destinationHash: fromHex(py!.destHash),
      content: 'offline hello',
      method: LxmfMethod.propagated,
    );
    await o.done.timeout(const Duration(seconds: 40));
    expect(o.state, LxmState.sent);
    expect(o.method, LxmfMethod.propagated);
    expect(o.propagationStampValue, greaterThanOrEqualTo(13));
    final r = await pySyncUntilReceived();
    expect(r['content'], 'offline hello');
    expect(r['source'], toHex(router.address));
    expect(r['signature_validated'], isTrue);
    expect(r['method'], LxmfMethod.propagated);
  });

  test('large message goes up as a resource (app flag) and is retrieved',
      () async {
    await start();
    final big = 'z' * 3000;
    final o = await router.send(
      destinationHash: fromHex(py!.destHash),
      content: big,
      method: LxmfMethod.propagated,
    );
    await o.done.timeout(const Duration(seconds: 60));
    expect(o.state, LxmState.sent);
    final r = await pySyncUntilReceived();
    expect(r['size'], 3000);
  });

  test('python -> dart via node: sync downloads, persists, then purges',
      () async {
    await start();
    await pySend('hello via node');
    await py!.waitFor('delivered');
    final persisted = <String>[];
    router.inboundPersister =
        (m) async => persisted.add(m.message.contentAsString);
    final got = router.incoming.first;
    final res = await router.syncInbox();
    expect(res.error, LxmSyncError.none, reason: '$res');
    expect(res.listed, 1);
    expect(res.delivered, 1);
    expect(res.purged, 1);
    final m = await got;
    expect(m.message.contentAsString, 'hello via node');
    expect(m.method, LxmfMethod.propagated);
    expect(persisted, ['hello via node']);
    expect(router.lastSync, same(res));
    // The node purged it: the next sync finds nothing.
    final again = await router.syncInbox();
    expect(again.listed, 0);
    expect(again.delivered, 0);
  });

  test('crash between download and persist: message stays on the node',
      () async {
    await start();
    await pySend('must survive');
    await py!.waitFor('delivered');
    router.inboundPersister = (m) async => throw StateError('disk full');
    final a = await router.syncInbox();
    expect(a.downloaded, 1);
    expect(a.persistFailed, 1);
    expect(a.delivered, 0);
    expect(a.purged, 0, reason: 'no haves before persistence');
    expect(a.remaining, 1);

    // "Restart": persistence works again, the node still has the message.
    final persisted = <String>[];
    router.inboundPersister =
        (m) async => persisted.add(m.message.contentAsString);
    final b = await router.syncInbox();
    expect(b.delivered, 1);
    expect(b.purged, 1);
    expect(persisted, ['must survive']);
    expect((await router.syncInbox()).listed, 0);
  });

  test('same message arriving directly and via the node is delivered once',
      () async {
    await start();
    final got = <LxmReceived>[];
    router.incoming.listen(got.add);
    const ts = 1700000000.5;
    await pySend('both ways', method: 'propagated', ts: ts);
    await py!.waitFor('delivered');
    await pySend('both ways', method: 'direct', ts: ts);
    await until(() => got.isNotEmpty, timeout: const Duration(seconds: 30));
    final res = await router.syncInbox();
    expect(res.duplicates, 1, reason: '$res');
    expect(res.delivered, 0);
    expect(res.purged, 1, reason: 'duplicate is still purged from the node');
    expect(got, hasLength(1));
    expect(got.single.method, LxmfMethod.direct);
  });

  test('node enforces the stamp cost: a too cheap stamp is rejected', () async {
    await start(
      config: const LxmRouterConfig(
        processInterval: Duration(milliseconds: 200),
        autoSync: false,
        propagationSyncInterval: null,
        propagationStampCostOverride: 0,
      ),
    );
    final o = await router.send(
      destinationHash: fromHex(py!.destHash),
      content: 'cheap',
      method: LxmfMethod.propagated,
    );
    await o.done.timeout(const Duration(seconds: 40));
    expect(o.state, LxmState.rejected);
    py!.send({'cmd': 'sync'});
    final s = await py!.waitFor('sync_done');
    expect(s['result'], 0, reason: 'node stored nothing');
  });

  test('node limit: message over the per-message limit fails client-side',
      () async {
    await start(nodeArgs: ['--pn-limit', '1']);
    final o = await router.send(
      destinationHash: fromHex(py!.destHash),
      content: 'q' * 2000,
      method: LxmfMethod.propagated,
    );
    await o.done.timeout(const Duration(seconds: 30));
    expect(o.state, LxmState.failed);
    expect(o.error, contains('too large'));
  });

  test('download respects our transfer limit; oversize stays on the node',
      () async {
    await start(
      config: const LxmRouterConfig(
        processInterval: Duration(milliseconds: 200),
        autoSync: false,
        propagationSyncInterval: null,
        deliveryPerTransferLimit: 2000,
      ),
    );
    await pySend('', size: 5000); // far over our 2 kB limit
    await py!.waitFor('delivered');
    await pySend('small one');
    await py!.waitFor('delivered');
    final res = await router.syncInbox();
    expect(res.listed, 2);
    expect(res.delivered, 1, reason: '$res');
    expect(res.remaining, 1);
    expect(res.purged, 1);
  });

  test('fallback: failed delivery to an offline peer goes via the node',
      () async {
    await start(
      withClient: false,
      config: const LxmRouterConfig(
        processInterval: Duration(milliseconds: 200),
        deliveryRetryWait: Duration(seconds: 1),
        pathRequestWait: Duration(seconds: 1),
        maxDeliveryAttempts: 2,
        autoSync: false,
        propagationSyncInterval: null,
      ),
    );
    // Second dart node "B" that announces and then goes offline.
    final storageB = MemoryStorage();
    final idB = await Identity.generate();
    Future<(Reticulum, LxmRouter)> startB() async {
      final iface = TcpClientInterface(
        host: '127.0.0.1',
        port: pn.port,
        connectTimeout: const Duration(seconds: 2),
      );
      final r = await Reticulum.start(ReticulumConfig(
        interfaces: [iface],
        storage: storageB,
        transport: const TransportConfig(
            stampAnnounces: false, stampPathRequests: false),
      ));
      await waitOnline(iface);
      final lr = await LxmRouter.start(r, idB, displayName: 'B', config: fast);
      return (r, lr);
    }

    var (rB, lB) = await startB();
    await lB.announce();
    await until(() => router.peer(lB.address) != null);
    final addrB = lB.address;
    await lB.stop();
    await rB.stop();

    final events = <String>[];
    router.outboundEvents.listen((e) => events.add(e.stage));
    final o = await router.send(
      destinationHash: addrB,
      content: 'via fallback',
    );
    await o.done.timeout(const Duration(seconds: 90));
    expect(o.state, LxmState.sent);
    expect(o.method, LxmfMethod.propagated);
    expect(events, contains('fallback_propagated'));

    // B comes back (same identity and ratchets) and checks its mail.
    (rB, lB) = await startB();
    extras.add(() async {
      await lB.stop();
      await rB.stop();
    });
    await until(() => lB.propagationNodes.isNotEmpty);
    // B learns A's key from A's next announce so the signature verifies.
    for (var i = 0;
        i < 15 && rB.transport.recallIdentity(router.address) == null;
        i++) {
      await router.announce();
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    final inc = lB.incoming.first;
    final res = await lB.syncInbox();
    expect(res.delivered, 1, reason: '$res');
    final m = await inc;
    expect(m.message.contentAsString, 'via fallback');
    expect(m.method, LxmfMethod.propagated);
    expect(m.message.signatureValidated, isTrue);
  });

  test('fallback can be switched off', () async {
    await start(
      withClient: false,
      config: const LxmRouterConfig(
        processInterval: Duration(milliseconds: 200),
        deliveryRetryWait: Duration(seconds: 1),
        pathRequestWait: Duration(seconds: 1),
        maxDeliveryAttempts: 2,
        fallbackToPropagation: false,
        autoSync: false,
        propagationSyncInterval: null,
      ),
    );
    final idB = await Identity.generate();
    final destB = LXMessage.deliveryHash(idB);
    // B is only known by key (never reachable).
    dart.rememberDestination(idB.publicKey, 'lxmf', const ['delivery']);
    final o = await router.send(destinationHash: destB, content: 'nowhere');
    await o.done.timeout(const Duration(seconds: 60));
    expect(o.state, LxmState.failed);
    expect(o.method, isNot(LxmfMethod.propagated));
  });

  test('pinned node wins over automatic selection', () async {
    await start(withClient: false);
    final other = Uint8List.fromList(List.filled(16, 7));
    router.setPinnedNode(other);
    expect(router.activeNode, other);
    router.setPinnedNode(null);
    expect(toHex(router.activeNode!), pn.ready['pn_hash']);
  });
}
