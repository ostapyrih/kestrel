import 'dart:async';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import 'support/memory_interface.dart';

const _noStamps =
    TransportConfig(stampAnnounces: false, stampPathRequests: false);

// App data produced by LXMF 1.3.1 `get_propagation_node_app_data` (name
// "Golden PN", cost 14, flexibility 2, 128 kB / 2048 kB limits).
const _goldenEnabled =
    '98c2ce6b09b582c3cc80cd0800930e021283ccfea46c786d6400a5312e332e3101c409476f6c64656e20504e930e02cb4032000000000000';
const _goldenDisabled =
    '98c2ce6b09b582c2cc80cd0800930e021283ccfea46c786d6400a5312e332e3101c409476f6c64656e20504e930e02cb4032000000000000';

LxmPropagationNode _n(
  int seed, {
  int hops = 1,
  bool enabled = true,
  DateTime? seen,
}) =>
    LxmPropagationNode(
      hash: Uint8List.fromList(List.filled(16, seed)),
      data: PropagationNodeData.parse(
        PropagationNodeData.pack(enabled: enabled, name: 'n$seed'),
      )!,
      hops: hops,
      lastSeen: seen ?? DateTime.now(),
    );

void main() {
  group('propagation node announce decoding', () {
    test('decodes what LXMF 1.3.1 produces', () {
      final d = PropagationNodeData.parse(fromHex(_goldenEnabled))!;
      expect(d.enabled, isTrue);
      expect(d.name, 'Golden PN');
      expect(d.transferLimitKb, 128);
      expect(d.syncLimitKb, 2048);
      expect(d.stampCost, 14);
      expect(d.stampCostFlexibility, 2);
      expect(d.peeringCost, 18);
      expect(d.minAcceptedCost, 12);
      expect(d.timebase, greaterThan(0));
      expect(PropagationNodeData.parse(fromHex(_goldenDisabled))!.enabled,
          isFalse);
    });

    test('pack / parse round trip incl. fractional cost', () {
      final b = PropagationNodeData.pack(
        stampCost: 16.5,
        stampCostFlexibility: 3,
        name: 'Zed',
        transferLimitKb: 64,
      );
      final d = PropagationNodeData.parse(b)!;
      expect(d.stampCost, 16.5, reason: 'transitional fractional element');
      expect(d.name, 'Zed');
      expect(d.transferLimitKb, 64);
    });

    test('invalid data is rejected like pn_announce_data_is_valid', () {
      expect(PropagationNodeData.parse(null), isNull);
      expect(PropagationNodeData.parse(const []), isNull);
      expect(PropagationNodeData.parse(const [1, 2, 3]), isNull);
      // too short (deprecated LXMF)
      expect(
          PropagationNodeData.parse(packb(<Object?>[false, 1, true])), isNull);
      // enabled flag not a bool
      expect(
          PropagationNodeData.parse(packb(<Object?>[
            false,
            1,
            'yes',
            256,
            256,
            <Object?>[16, 3, 18],
            <Object?, Object?>{},
          ])),
          isNull);
      // costs not a list
      expect(
          PropagationNodeData.parse(packb(<Object?>[
            false,
            1,
            true,
            256,
            256,
            16,
            <Object?, Object?>{},
          ])),
          isNull);
      // a delivery announce is not a propagation announce
      expect(
          PropagationNodeData.parse(LxmAnnounceData.pack(displayName: 'Alice')),
          isNull);
    });

    test('name is optional', () {
      final d = PropagationNodeData.parse(PropagationNodeData.pack())!;
      expect(d.name, isNull);
    });
  });

  group('node selection', () {
    final now = DateTime.now();

    test('fewest hops wins, ties by most recent then hash', () {
      final a = _n(1, hops: 3);
      final b = _n(2, hops: 1, seen: now.subtract(const Duration(hours: 5)));
      final c = _n(3, hops: 1, seen: now.subtract(const Duration(hours: 1)));
      expect(
        PropagationNodeSelector.select([a, b, c], now: now),
        c.hash,
      );
      final d = _n(4, hops: 1, seen: c.lastSeen);
      expect(PropagationNodeSelector.select([d, c], now: now), c.hash);
    });

    test('disabled, stale and unreachable nodes are skipped', () {
      final off = _n(1, hops: 1, enabled: false);
      final old = _n(2, hops: 1, seen: now.subtract(const Duration(days: 5)));
      final dead = _n(3, hops: 1);
      final ok = _n(4, hops: 6);
      expect(
        PropagationNodeSelector.select(
          [off, old, dead, ok],
          now: now,
          unreachable: {dead.hashHex},
        ),
        ok.hash,
      );
      expect(PropagationNodeSelector.select([off, old], now: now), isNull);
    });

    test('sticks to the current node while it is a candidate', () {
      final far = _n(1, hops: 5);
      final near = _n(2, hops: 1);
      expect(
        PropagationNodeSelector.select([far, near],
            now: now, current: far.hash),
        far.hash,
      );
      // ... but not once it is unreachable
      expect(
        PropagationNodeSelector.select(
          [far, near],
          now: now,
          current: far.hash,
          unreachable: {far.hashHex},
        ),
        near.hash,
      );
    });

    test('a preferred node wins unless unreachable; pin beats it', () {
      final near = _n(2, hops: 1);
      final pref = Uint8List.fromList(List.filled(16, 9));
      final prefHex = toHex(pref);
      expect(
        PropagationNodeSelector.select([near], now: now, preferred: pref),
        pref,
      );
      expect(
        PropagationNodeSelector.select([near],
            now: now, preferred: pref, unreachable: {prefHex}),
        near.hash,
      );
      final pin = Uint8List.fromList(List.filled(16, 5));
      expect(
        PropagationNodeSelector.select([near],
            now: now, preferred: pref, pinned: pin),
        pin,
      );
    });

    test('a pinned node always wins, even if unknown', () {
      final near = _n(2, hops: 1);
      final pinned = Uint8List.fromList(List.filled(16, 9));
      expect(
        PropagationNodeSelector.select([near], now: now, pinned: pinned),
        pinned,
      );
    });
  });

  group('propagation stamps', () {
    test('generate + validate (expanded and non-expanded workblock)', () {
      final tid = sha256([1, 2, 3]);
      final g = LxmStamper.generatePnSync(tid, 8);
      expect(g.value, greaterThanOrEqualTo(8));
      expect(LxmStamper.validatePnSync(g.stamp, 8, tid), isNotNull);
      expect(LxmStamper.validatePnSync(g.stamp, 8, sha256([9])), isNull,
          reason: 'bound to the transient id');
      // 1000 rounds, not 3000 like message stamps
      expect(LxmStamper.workblock(tid, expandRounds: 1000).length, 256000);
    });

    test('transient id excludes the stamp; withStamp appends it', () async {
      final sender = await Identity.generate();
      final rcpt = await Identity.generate();
      final m = LXMessage(
        destinationHash: LXMessage.deliveryHash(rcpt),
        sourceHash: LXMessage.deliveryHash(sender),
        content: 'x',
      );
      await m.pack(sender);
      final pp = await m.propagationPacked(rcpt, now: 1700000000);
      final stamp = Uint8List.fromList(List.filled(32, 5));
      final withStamp = unpackb(pp.withStamp(stamp))! as List<Object?>;
      final data = (withStamp[1]! as List<Object?>).single as Uint8List;
      expect(data.length, pp.lxmfData.length + 32);
      expect(data.sublist(0, pp.lxmfData.length), pp.lxmfData);
      expect(sha256(data.sublist(0, data.length - 32)), pp.transientId);
    });
  });

  group('router with a scripted propagation node', () {
    late Reticulum rnsNode, rnsClient;
    late LxmRouter router;
    late _FakeNode fake;
    late Identity me;
    Identity? senderId;

    Future<void> setUp0({
      LxmRouterConfig config = const LxmRouterConfig(
        processInterval: Duration(milliseconds: 100),
        autoSync: false,
        propagationSyncInterval: null,
      ),
      bool announceNode = true,
    }) async {
      final (ia, ib) = MemoryInterface.pair(mtu: 262144);
      rnsNode = await Reticulum.start(
          ReticulumConfig(interfaces: [ia], transport: _noStamps));
      rnsClient = await Reticulum.start(
          ReticulumConfig(interfaces: [ib], transport: _noStamps));
      me = await Identity.generate();
      senderId = null;
      router = await LxmRouter.start(rnsClient, me,
          displayName: 'Me', config: config);
      fake = await _FakeNode.start(rnsNode);
      if (announceNode) {
        final heard = router.propagationUpdates.first;
        await fake.announce();
        await heard.timeout(const Duration(seconds: 5));
      }
    }

    tearDown(() async {
      await router.stop();
      await rnsClient.stop();
      await rnsNode.stop();
    });

    Future<Uint8List> stored(String text,
        {Identity? to, int tamper = 0}) async {
      final sender = senderId ??= await Identity.generate();
      final rcpt = to ?? me;
      final m = LXMessage(
        destinationHash: LXMessage.deliveryHash(rcpt),
        sourceHash: LXMessage.deliveryHash(sender),
        content: text,
        timestamp: 1700000000.0 + text.length,
      );
      await m.pack(sender);
      final pp = await m.propagationPacked(rcpt, now: 1700000000);
      final data = Uint8List.fromList(pp.lxmfData);
      if (tamper > 0) data[data.length - 1] ^= 0xFF; // breaks the HMAC
      fake.messages[toHex(sha256(data))] = data;
      return sha256(data);
    }

    test('discovers the node from its announce', () async {
      await setUp0();
      final n = router.propagationNodes.single;
      expect(n.name, 'Fake PN');
      expect(n.hops, 1);
      expect(router.activeNode, n.hash);
    });

    test('sync persists every message before the node is told to purge',
        () async {
      await setUp0();
      await stored('one');
      await stored('two');
      final log = fake.log;
      router.inboundPersister = (m) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        log.add('persist:${m.message.contentAsString}');
      };
      final r = await router.syncInbox();
      expect(r.error, LxmSyncError.none, reason: '$r');
      expect(r.listed, 2);
      expect(r.delivered, 2);
      expect(r.purged, 2);
      expect(r.remaining, 0);
      final firstPurge = log.indexWhere((e) => e.startsWith('haves:'));
      final lastPersist = log.lastIndexWhere((e) => e.startsWith('persist:'));
      expect(firstPurge, greaterThan(lastPersist),
          reason: 'haves only after all persisted: $log');
      expect(fake.messages, isEmpty);
      expect(router.lastSync, same(r));
    });

    test('persist failure keeps the message on the node (no haves)', () async {
      await setUp0();
      await stored('keep me');
      router.inboundPersister = (m) async => throw StateError('io');
      final r = await router.syncInbox();
      expect(r.persistFailed, 1);
      expect(r.delivered, 0);
      expect(r.purged, 0);
      expect(r.remaining, 1);
      expect(fake.messages, hasLength(1));
      expect(fake.log.where((e) => e.startsWith('haves:')), isEmpty);
      // The claim was released: a retry delivers it.
      router.inboundPersister = null;
      final r2 = await router.syncInbox();
      expect(r2.delivered, 1);
      expect(fake.messages, isEmpty);
    });

    test('undecryptable messages are not purged', () async {
      await setUp0();
      await stored('broken', tamper: 1);
      await stored('fine');
      final r = await router.syncInbox();
      expect(r.undecryptable, 1);
      expect(r.delivered, 1);
      expect(fake.messages, hasLength(1), reason: 'broken one kept');
    });

    test('duplicates (already received directly) are purged, not redelivered',
        () async {
      await setUp0();
      final seen = <String>[];
      router.incoming.listen((m) => seen.add(m.message.contentAsString));
      await stored('twice');
      await router.syncInbox();
      // The same message hash shows up on the node again.
      fake.messages.clear();
      await stored('twice');
      final r = await router.syncInbox();
      expect(r.duplicates, 1, reason: '$r');
      expect(r.delivered, 0);
      expect(r.purged, 1);
      expect(seen, ['twice']);
    });

    test('a failed confirmation is retried as haves, never re-delivered',
        () async {
      await setUp0();
      await stored('a');
      fake.failConfirm = true;
      final r = await router.syncInbox();
      expect(r.delivered, 1);
      expect(r.purged, 0, reason: 'confirmation lost');
      expect(fake.messages, hasLength(1));
      fake.failConfirm = false;
      final r2 = await router.syncInbox();
      expect(r2.delivered, 0);
      expect(r2.purged, 1);
      expect(fake.messages, isEmpty);
    });

    test('node error codes map to sync errors', () async {
      await setUp0();
      fake.errorCode = 0xf1;
      expect((await router.syncInbox()).error, LxmSyncError.noAccess);
      fake.errorCode = 0xf0;
      expect((await router.syncInbox()).error, LxmSyncError.noIdentity);
      fake.errorCode = null;
      expect((await router.syncInbox()).error, LxmSyncError.none);
    });

    test('download limit is sent to the node (kB)', () async {
      await setUp0(
        config: const LxmRouterConfig(
          processInterval: Duration(milliseconds: 100),
          autoSync: false,
          propagationSyncInterval: null,
          deliveryPerTransferLimit: 1234000,
        ),
      );
      await stored('lim');
      await router.syncInbox();
      expect(fake.lastLimitKb, 1234);
    });

    test('no node known / disabled / multi-device hook', () async {
      await setUp0(announceNode: false);
      expect((await router.syncInbox()).error, LxmSyncError.noNode);
      router.inboxSyncEnabled = false;
      expect((await router.syncInbox()).error, LxmSyncError.disabled);
    });

    test('auto sync runs when a node is heard (start/connect trigger)',
        () async {
      await setUp0(
        announceNode: false,
        config: const LxmRouterConfig(
          processInterval: Duration(milliseconds: 100),
          propagationSyncInterval: null,
        ),
      );
      await stored('auto');
      final got = router.incoming.first;
      await fake.announce();
      final m = await got.timeout(const Duration(seconds: 10));
      expect(m.message.contentAsString, 'auto');
    });

    test('periodic sync interval can be set', () async {
      await setUp0(
        config: const LxmRouterConfig(
          processInterval: Duration(milliseconds: 100),
          propagationSyncInterval: Duration(milliseconds: 300),
          autoSyncMinGap: Duration(milliseconds: 10),
        ),
      );
      await router.syncInbox();
      final before = fake.listCalls;
      await stored('later');
      final got = router.incoming.first;
      await got.timeout(const Duration(seconds: 10));
      expect(fake.listCalls, greaterThan(before));
      router.setSyncInterval(null);
    });

    test('pinning a node overrides automatic selection', () async {
      await setUp0();
      final auto = router.activeNode;
      final pin = Uint8List.fromList(List.filled(16, 3));
      router.setPinnedNode(pin);
      expect(router.activeNode, pin);
      expect(router.pinnedNode, pin);
      router.setPinnedNode(null);
      expect(router.activeNode, auto);
    });

    test('default node: used when heard, even if a nearer one exists', () async {
      await setUp0();
      final heard = router.propagationNodes.single.hash;
      router.setDefaultNode(heard);
      expect(router.activeNode, heard);
      expect(router.defaultNode, heard);
      expect(router.pinnedNode, isNull);
    });

    test('default node: used before it is heard; pin and clear override it',
        () async {
      await setUp0();
      final auto = router.activeNode;
      final dflt = Uint8List.fromList(List.filled(16, 7));
      router.setDefaultNode(dflt);
      expect(router.activeNode, dflt, reason: 'unheard default still wins');
      final pin = Uint8List.fromList(List.filled(16, 3));
      router.setPinnedNode(pin);
      expect(router.activeNode, pin);
      router.setPinnedNode(null);
      expect(router.activeNode, dflt);
      router.setDefaultNode(null);
      expect(router.activeNode, auto);
    });

    test('failing default falls back to automatic, then is retried', () async {
      await setUp0(
        config: const LxmRouterConfig(
          processInterval: Duration(milliseconds: 100),
          autoSync: false,
          propagationSyncInterval: null,
          nodeUnreachableFor: Duration(seconds: 2),
          propagationPathWait: Duration(milliseconds: 300),
        ),
      );
      final auto = router.activeNode!;
      final dflt = Uint8List.fromList(List.filled(16, 7));
      router.setDefaultNode(dflt);
      expect(router.activeNode, dflt);
      for (var i = 0; i < 2; i++) {
        final r = await router.syncInbox();
        expect(r.ok, isFalse);
      }
      expect(router.isNodeUnreachable(dflt), isTrue);
      expect(router.activeNode, auto);
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(router.isNodeUnreachable(dflt), isFalse);
      expect(router.activeNode, dflt, reason: 'default retried later');
    });

    test('propagated send without any node fails after nodeWait', () async {
      await setUp0(
        announceNode: false,
        config: const LxmRouterConfig(
          processInterval: Duration(milliseconds: 100),
          nodeWait: Duration(milliseconds: 300),
          autoSync: false,
          propagationSyncInterval: null,
        ),
      );
      final other = await Identity.generate();
      rnsClient
          .rememberDestination(other.publicKey, 'lxmf', const ['delivery']);
      final o = await router.send(
        destinationHash: LXMessage.deliveryHash(other),
        content: 'x',
        method: LxmfMethod.propagated,
      );
      await o.done.timeout(const Duration(seconds: 10));
      expect(o.state, LxmState.failed);
      expect(o.error, contains('no propagation node'));
    });

    test('propagated upload: stamped, accepted by the node, state sent',
        () async {
      await setUp0();
      final other = await Identity.generate();
      rnsClient
          .rememberDestination(other.publicKey, 'lxmf', const ['delivery']);
      final o = await router.send(
        destinationHash: LXMessage.deliveryHash(other),
        content: 'to the node',
        method: LxmfMethod.propagated,
      );
      await o.done.timeout(const Duration(seconds: 30));
      expect(o.state, LxmState.sent);
      expect(fake.uploads, hasLength(1));
      final up = fake.uploads.single;
      // stamp valid for the announced cost
      final lxmfData = up.sublist(0, up.length - 32);
      final stamp = up.sublist(up.length - 32);
      expect(
        LxmStamper.validatePnSync(stamp, 13, sha256(lxmfData)),
        isNotNull,
      );
    });
  });
}

/// A scripted propagation node on a second Reticulum instance: serves `/get`
/// (list / get / haves) from [messages] and accepts uploads, logging what a
/// real node would see.
class _FakeNode {
  _FakeNode._(this.rns, this.dest);

  final Reticulum rns;
  final Destination dest;
  final Map<String, Uint8List> messages = {};
  final List<String> log = [];
  final List<Uint8List> uploads = [];
  int? errorCode;
  bool failConfirm = false;
  int? lastLimitKb;
  int listCalls = 0;

  static Future<_FakeNode> start(Reticulum rns) async {
    final id = await Identity.generate();
    final d = await rns.createDestination(id, 'lxmf', const ['propagation']);
    final n = _FakeNode._(rns, d);
    d.registerRequestHandler('/get', n._get, policy: RequestPolicy.all);
    d.onLinkEstablished = (l) {
      final link = l as Link;
      link.onPacket = (data, packet) {
        final u = unpackb(data)! as List<Object?>;
        final msgs = u[1]! as List<Object?>;
        for (final m in msgs) {
          n.uploads.add(m! as Uint8List);
        }
        unawaited(link.provePacket(packet));
      };
    };
    return n;
  }

  Future<void> announce() => rns.announce(
        dest,
        appData: PropagationNodeData.pack(name: 'Fake PN', stampCost: 13),
      );

  Object? _get(String path, Object? data, Uint8List requestId, Uint8List linkId,
      Identity? remote, double at) {
    if (errorCode != null) return errorCode;
    final d = data! as List<Object?>;
    final wants = d[0] as List<Object?>?;
    final haves = d[1] as List<Object?>?;
    if (wants == null && haves == null) {
      listCalls++;
      return [for (final k in messages.keys) fromHex(k)];
    }
    if (d.length > 2) lastLimitKb = d[2] as int?;
    if (haves != null && haves.isNotEmpty) {
      if (wants == null && failConfirm) return 0xf1;
      log.add('haves:${haves.length}');
      for (final h in haves) {
        messages.remove(toHex(h! as Uint8List));
      }
    }
    if (wants == null) return <Object?>[];
    return [
      for (final w in wants)
        if (messages[toHex(w! as Uint8List)] != null)
          messages[toHex(w as Uint8List)],
    ];
  }
}
