import 'dart:async';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import 'support/it_support.dart' show until;
import 'support/memory_interface.dart';

/// Phase S1 primitives: announce control (silent destinations, monotonic
/// timebase), announce stamp copy, ratchet export/merge.
const _fast = TransportConfig(
  stampAnnounces: false,
  stampPathRequests: false,
  perHopTimeout: Duration(milliseconds: 300),
);

Future<(Reticulum, Reticulum)> _pair({TransportConfig config = _fast}) async {
  final (ia, ib) = MemoryInterface.pair();
  final a = await Reticulum.start(
      ReticulumConfig(interfaces: [ia], transport: config));
  final b = await Reticulum.start(
      ReticulumConfig(interfaces: [ib], transport: config));
  return (a, b);
}

Future<Reticulum> _lone({TransportConfig config = _fast}) async {
  final (ia, _) = MemoryInterface.pair();
  return Reticulum.start(ReticulumConfig(interfaces: [ia], transport: config));
}

void main() {
  group('AnnounceTimebase', () {
    test('is max(now, last + 1) and never repeats a second', () {
      final t = AnnounceTimebase();
      expect(t.next(nowSeconds: 1000), 1000);
      expect(t.next(nowSeconds: 1000), 1001);
      expect(t.next(nowSeconds: 1000), 1002);
      expect(t.next(nowSeconds: 2000), 2000);
    });

    test('a clock that runs behind still moves forward after observe', () {
      final seen = <int>[];
      final t = AnnounceTimebase(onChanged: seen.add);
      expect(t.observe(5000), isTrue);
      expect(t.observe(4000), isFalse); // only forward
      expect(t.next(nowSeconds: 4880), 5001);
      expect(seen, [5000, 5001]);
      expect(t.lastEmitted, 5001);
    });

    test('announces carry the timebase as emission time', () async {
      final (a, b) = await _pair();
      addTearDown(a.stop);
      addTearDown(b.stop);
      final id = await Identity.generate();
      final d = await a.createDestination(id, 'kestrel', ['tb']);
      d.announceTimebase = AnnounceTimebase(lastEmitted: 5000);
      a.transport.clockSeconds = () => 100; // far behind
      final got = b.announces.first;
      expect(await a.announce(d), isTrue);
      final e = await got.timeout(const Duration(seconds: 5));
      expect(e.announce.emittedAt, 5001);
      final got2 = b.announces.first;
      await a.announce(d);
      expect(
          (await got2.timeout(const Duration(seconds: 5))).announce.emittedAt,
          5002);
    });
  });

  group('silent destinations', () {
    test('are never announced and never answer path requests', () async {
      final (a, b) = await _pair();
      addTearDown(a.stop);
      addTearDown(b.stop);
      final id = await Identity.generate();
      final d = await a.createDestination(id, 'kestrel', ['silent']);
      d.silent = true;
      var heard = 0;
      final sub = b.announces.listen((_) => heard++);
      addTearDown(sub.cancel);

      expect(await a.announce(d), isFalse);
      await b.requestPath(d.hash);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(heard, 0);
      expect(b.transport.hasPath(d.hash), isFalse);

      // The elected announcer answers again after it is un-silenced.
      d.silent = false;
      final got = b.announces.first;
      await b.requestPath(d.hash);
      final e = await got.timeout(const Duration(seconds: 5));
      expect(e.isPathResponse, isTrue);
      expect(b.transport.hasPath(d.hash), isTrue);
    });

    test('still decrypt traffic that reaches them', () async {
      final (a, b) = await _pair();
      addTearDown(a.stop);
      addTearDown(b.stop);
      final id = await Identity.generate();
      final d = await a.createDestination(id, 'kestrel', ['silent2']);
      final got = Completer<Uint8List>();
      d.onPacket = (data, _) => got.complete(data);
      await a.announce(d);
      await until(() => b.transport.hasPath(d.hash));
      d.silent = true;
      final out = b.recallDestination(d.hash, 'kestrel', ['silent2'])!;
      await b.send(out, [1, 2, 3]);
      expect(await got.future.timeout(const Duration(seconds: 5)), [1, 2, 3]);
    });
  });

  group('announce stamp copy', () {
    const stamped = TransportConfig(
      stampAnnounces: true,
      announceStampValue: 8,
      requiredAnnounceStampCost: 8,
      stampPathRequests: false,
    );

    test('export on one device, import on another, no regeneration', () async {
      final a = await _lone(config: stamped);
      final c = await _lone(config: stamped);
      addTearDown(a.stop);
      addTearDown(c.stop);
      final id = await Identity.generate();
      final da = await a.createDestination(id, 'kestrel', ['st']);
      final dc = await c.createDestination(id, 'kestrel', ['st']);
      expect(await a.transport.exportStamp(da), isNull,
          reason: 'export never generates');
      final s = (await a.transport.ensureStamp(da))!;
      final exported = await a.transport.exportStamp(da);
      expect(exported, s);
      expect(await c.transport.importStamp(dc, s), isTrue);
      expect(await c.transport.ensureStamp(dc), s,
          reason: 'copied, not regenerated');
    });

    test('rejects a stamp of another destination or too low a value', () async {
      final a = await _lone(config: stamped);
      addTearDown(a.stop);
      final d1 = await a
          .createDestination(await Identity.generate(), 'kestrel', ['st']);
      final d2 = await a
          .createDestination(await Identity.generate(), 'kestrel', ['st']);
      final s1 = (await a.transport.ensureStamp(d1))!;
      expect(await a.transport.importStamp(d2, s1), isFalse);
      expect(await a.transport.importStamp(d2, Uint8List(14)), isFalse);
      expect(await a.transport.importStamp(d2, [1, 2]), isFalse);
      expect(d2.stamp, isNull);
    });
  });

  group('ratchet export and merge', () {
    Future<Destination> dest(Reticulum r, Identity id) =>
        r.createDestination(id, 'kestrel', ['rat'], ratchets: true);

    test('merge is a union, newest first, never overwrites', () async {
      final r = await _lone();
      addTearDown(r.stop);
      final id = await Identity.generate();
      final x = await dest(r, id);
      final r2 = await _lone();
      addTearDown(r2.stop);
      final y = await dest(r2, id);

      await x.rotateRatchets(nowSeconds: 1000);
      await x.rotateRatchets(nowSeconds: 1000 + 31 * 60);
      await y.rotateRatchets(nowSeconds: 1500);
      final yOwn = y.ratchets!.single;
      final xKeys = [for (final k in x.ratchets!) k];

      final added = await y.mergeRatchets(x.exportRatchets());
      expect(added, 2);
      expect(y.ratchets!.length, 3);
      // creation times: x2 (2860) > y (1500) > x1 (1000)
      expect(y.ratchets![0], xKeys[0]);
      expect(y.ratchets![1], yOwn);
      expect(y.ratchets![2], xKeys[1]);
      // idempotent
      expect(await y.mergeRatchets(x.exportRatchets()), 0);
      expect(y.ratchets!.length, 3);
      // merging an older snapshot never drops local keys
      expect(await y.mergeRatchets([x.exportRatchets().last]), 0);
      expect(y.ratchets!.length, 3);
    });

    test('merged ratchets decrypt; without the merge they do not', () async {
      final r = await _lone();
      final r2 = await _lone();
      addTearDown(r.stop);
      addTearDown(r2.stop);
      final id = await Identity.generate();
      final x = await dest(r, id);
      final y = await dest(r2, id);
      final pubX = await x.rotateRatchets(nowSeconds: 1000);
      await y.rotateRatchets(nowSeconds: 1000);
      final out = Destination.single(
        Identity.fromPublicKey(id.publicKey),
        'kestrel',
        ['rat'],
        direction: DestinationDirection.outbound,
      );
      final ct = await out.encrypt([9, 9], ratchet: pubX);
      expect(await y.decrypt(ct, ratchets: y.ratchets, enforceRatchets: true),
          isNull,
          reason: 'C1: peer cached the other device ratchet');
      await y.mergeRatchets(x.exportRatchets());
      expect(await y.decrypt(ct, ratchets: y.ratchets), [9, 9]);
    });

    test('cap is retainedRatchets, oldest dropped', () async {
      final r = await _lone();
      addTearDown(r.stop);
      final id = await Identity.generate();
      final y = await dest(r, id)
        ..retainedRatchets = 3;
      final incoming = [
        for (var i = 0; i < 5; i++)
          RatchetEntry(Identity.generateRatchet(), 100 + i),
      ];
      await y.mergeRatchets(incoming);
      expect(y.ratchets!.length, 3);
      expect(y.ratchets!.first, incoming[4].key);
      expect(y.ratchets!.last, incoming[2].key);
    });

    test('a non-rotating device announces the shared ratchet unchanged',
        () async {
      final r = await _lone();
      final r2 = await _lone();
      addTearDown(r.stop);
      addTearDown(r2.stop);
      final id = await Identity.generate();
      final x = await dest(r, id);
      final y = await dest(r2, id);
      final pubX = await x.rotateRatchets();
      await y.mergeRatchets(x.exportRatchets());
      y.ratchetRotationAllowed = false;
      expect(await y.rotateRatchets(nowSeconds: 1 << 40), pubX);
      expect(y.ratchets!.length, 1);
      // Even when the interval elapsed, a merged recent ratchet postpones
      // rotation on a device that may rotate.
      y.ratchetRotationAllowed = true;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(await y.rotateRatchets(nowSeconds: now + 60), pubX);
    });

    test('creation times survive persistence', () async {
      final storage = MemoryStorage();
      final (ia, _) = MemoryInterface.pair();
      final r1 = await Reticulum.start(ReticulumConfig(
          interfaces: [ia], storage: storage, transport: _fast));
      final id = await Identity.generate();
      final d1 = await dest(r1, id);
      await d1.rotateRatchets(nowSeconds: 777);
      await r1.stop();
      final (ib, _) = MemoryInterface.pair();
      final r2 = await Reticulum.start(ReticulumConfig(
          interfaces: [ib], storage: storage, transport: _fast));
      addTearDown(r2.stop);
      final d2 = await dest(r2, id);
      expect(d2.exportRatchets().single.createdAt, 777);
    });
  });
}
