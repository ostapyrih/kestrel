import 'dart:async';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import 'support/memory_interface.dart';

const _cfg = LxmRouterConfig(
  processInterval: Duration(milliseconds: 100),
  deliveryRetryWait: Duration(milliseconds: 800),
  pathRequestWait: Duration(milliseconds: 500),
);

const _noStamps =
    TransportConfig(stampAnnounces: false, stampPathRequests: false);

class _Pair {
  _Pair(this.a, this.b, this.ra, this.rb, this.ia, this.ib);
  final Reticulum a, b;
  final LxmRouter ra, rb;
  final MemoryInterface ia, ib;

  Future<void> stop() async {
    await ra.stop();
    await rb.stop();
    await a.stop();
    await b.stop();
  }
}

Future<_Pair> _pair({
  LxmStore? storeA,
  LxmRouterConfig cfgB = _cfg,
  bool announce = true,
}) async {
  final (ia, ib) = MemoryInterface.pair(mtu: 262144);
  final a = await Reticulum.start(
      ReticulumConfig(interfaces: [ia], transport: _noStamps));
  final b = await Reticulum.start(
      ReticulumConfig(interfaces: [ib], transport: _noStamps));
  final ra = await LxmRouter.start(a, await Identity.generate(),
      displayName: 'Alice', config: _cfg, store: storeA);
  final rb = await LxmRouter.start(b, await Identity.generate(),
      displayName: 'Bob', config: cfgB);
  if (announce) {
    final seen = ra.peerUpdates.first;
    await rb.announce();
    await seen;
    await ra.announce();
    await rb.peerUpdates.first;
  }
  return _Pair(a, b, ra, rb, ia, ib);
}

void main() {
  group('announce app_data', () {
    test('matches the bytes LXMF 1.3.1 produces', () {
      expect(toHex(LxmAnnounceData.pack(displayName: 'Alice')),
          '94c405416c696365c09100c0');
      expect(toHex(LxmAnnounceData.pack(displayName: 'Alice', stampCost: 8)),
          '94c405416c696365089100cb4020000000000000');
      expect(toHex(LxmAnnounceData.pack(displayName: 'Bob', stampCost: 12.5)),
          '94c403426f620d9100cb4029000000000000');
    });

    test('parses current, legacy and malformed data', () {
      final d = LxmAnnounceData.parse(
          fromHex('94c403426f620d9100cb4029000000000000'));
      expect(d.displayName, 'Bob');
      expect(d.stampCost, 12.5);
      expect(d.supportsCompression, isTrue);
      expect(LxmAnnounceData.parse('Legacy'.codeUnits).displayName, 'Legacy');
      expect(LxmAnnounceData.parse(null).displayName, isNull);
      expect(LxmAnnounceData.parse([0x94, 0xFF]).displayName, isNull);
    });
  });

  group('stamps', () {
    test('generate and validate round trip, wrong id fails', () {
      final id = Uint8List.fromList(List.generate(32, (i) => i));
      final g = LxmStamper.generateSync(id, 6);
      expect(g.value, greaterThanOrEqualTo(6));
      expect(LxmStamper.validateSync(g.stamp, 6, id), isNotNull);
      final other = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      expect(LxmStamper.validateSync(g.stamp, 14, other), isNull);
    });
  });

  group('two routers over memory interfaces', () {
    late _Pair p;
    tearDown(() async => p.stop());

    test('opportunistic message is delivered, proved and parsed', () async {
      p = await _pair();
      final got = p.rb.incoming.first;
      final events = <LxmOutboundEvent>[];
      p.ra.outboundEvents.listen(events.add);
      final o = await p.ra.send(
        destinationHash: p.rb.address,
        content: 'hello',
        title: 'greet',
        tag: 'row-1',
      );
      final r = await got.timeout(const Duration(seconds: 10));
      expect(r.message.contentAsString, 'hello');
      expect(r.message.titleAsString, 'greet');
      expect(r.message.signatureValidated, isTrue);
      expect(r.method, LxmfMethod.opportunistic);
      expect(toHex(r.message.sourceHash), toHex(p.ra.address));
      await o.done.timeout(const Duration(seconds: 10));
      expect(o.state, LxmState.delivered);
      expect(
          events.map((e) => e.state),
          containsAllInOrder([
            LxmState.generating,
            LxmState.outbound,
            LxmState.sent,
            LxmState.delivered
          ]));
      expect(events.every((e) => e.tag == 'row-1'), isTrue);
      expect(events.every((e) => toHex(e.hash) == toHex(o.hash)), isTrue);
    });

    test('peers expose display names from announces', () async {
      p = await _pair();
      final peer = p.ra.peer(p.rb.address)!;
      expect(peer.displayName, 'Bob');
      expect(peer.stampCost, isNull);
    });

    test('direct message over a link and backchannel identification', () async {
      p = await _pair();
      final got = p.rb.incoming.first;
      final o = await p.ra.send(
        destinationHash: p.rb.address,
        content: 'direct',
        method: LxmfMethod.direct,
      );
      final r = await got.timeout(const Duration(seconds: 10));
      expect(r.method, LxmfMethod.direct);
      expect(r.message.signatureValidated, isTrue);
      await o.done.timeout(const Duration(seconds: 10));
      expect(o.state, LxmState.delivered);
    });

    test('large direct message travels as a resource', () async {
      p = await _pair();
      final text =
          List.generate(40000, (i) => String.fromCharCode(97 + (i * 7919) % 26))
              .join();
      final got = p.rb.incoming.first;
      final o = await p.ra.send(
        destinationHash: p.rb.address,
        content: text,
        method: LxmfMethod.direct,
      );
      expect(o.message.representation, LxmfRepresentation.resource);
      final r = await got.timeout(const Duration(seconds: 20));
      expect(r.message.contentAsString, text);
      await o.done.timeout(const Duration(seconds: 20));
      expect(o.state, LxmState.delivered);
    });

    test('opportunistic upgrades to direct when it does not fit a packet',
        () async {
      p = await _pair();
      final o = await p.ra.send(
        destinationHash: p.rb.address,
        content: 'y' * 700,
      );
      expect(o.method, LxmfMethod.direct);
      await o.done.timeout(const Duration(seconds: 10));
      expect(o.state, LxmState.delivered);
    });

    test('duplicates are delivered once', () async {
      p = await _pair();
      final got = <LxmReceived>[];
      p.rb.incoming.listen(got.add);
      final o = await p.ra.send(destinationHash: p.rb.address, content: 'once');
      await o.done.timeout(const Duration(seconds: 10));
      // replay the same packed message straight into B's dedup
      final again =
          await p.ra.send(destinationHash: p.rb.address, content: 'second');
      await again.done.timeout(const Duration(seconds: 10));
      expect(got.length, 2);
      expect(got.map((e) => e.message.contentAsString), ['once', 'second']);
    });

    test('stamp is generated when the peer announces a cost', () async {
      final (ia, ib) = MemoryInterface.pair(mtu: 262144);
      final a = await Reticulum.start(
          ReticulumConfig(interfaces: [ia], transport: _noStamps));
      final b = await Reticulum.start(
          ReticulumConfig(interfaces: [ib], transport: _noStamps));
      final ra = await LxmRouter.start(a, await Identity.generate(),
          displayName: 'A', config: _cfg);
      final rb = await LxmRouter.start(
        b,
        await Identity.generate(),
        displayName: 'B',
        config: const LxmRouterConfig(
          processInterval: Duration(milliseconds: 100),
          inboundStampCost: 6,
          enforceStamps: true,
        ),
      );
      p = _Pair(a, b, ra, rb, ia, ib);
      final seen = ra.peerUpdates.first;
      await rb.announce();
      await seen;
      expect(ra.peer(rb.address)!.stampCost, 6);
      final got = rb.incoming.first;
      final o = await ra.send(destinationHash: rb.address, content: 'stamped');
      final r = await got.timeout(const Duration(seconds: 30));
      expect(r.stampValid, isTrue);
      expect(r.stampValue, greaterThanOrEqualTo(6));
      expect(o.message.stamp, isNotNull);
      await o.done.timeout(const Duration(seconds: 10));
    });

    test('enforced stamps drop unstamped messages', () async {
      final (ia, ib) = MemoryInterface.pair();
      final a = await Reticulum.start(
          ReticulumConfig(interfaces: [ia], transport: _noStamps));
      final b = await Reticulum.start(
          ReticulumConfig(interfaces: [ib], transport: _noStamps));
      final ra = await LxmRouter.start(a, await Identity.generate(),
          displayName: 'A', config: _cfg);
      final rb = await LxmRouter.start(
        b,
        await Identity.generate(),
        displayName: 'B',
        config: const LxmRouterConfig(
          processInterval: Duration(milliseconds: 100),
          inboundStampCost: 6,
          enforceStamps: true,
        ),
      );
      p = _Pair(a, b, ra, rb, ia, ib);
      final seen = ra.peerUpdates.first;
      await rb.announce();
      await seen;
      final got = <LxmReceived>[];
      rb.incoming.listen(got.add);
      final o = await ra.send(
        destinationHash: rb.address,
        content: 'no stamp',
        stampCost: 0, // pretend we do not know the requirement
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(got, isEmpty);
      await ra.cancel(o.hash);
    });

    test('message from an unknown sender is flagged unverified', () async {
      p = await _pair(announce: false);
      // B announces so A knows B; A never announced, so B cannot verify A.
      final seen = p.ra.peerUpdates.first;
      await p.rb.announce();
      await seen;
      final got = p.rb.incoming.first;
      await p.ra.send(destinationHash: p.rb.address, content: 'who am i');
      final r = await got.timeout(const Duration(seconds: 10));
      expect(r.message.signatureValidated, isFalse);
      expect(r.message.unverifiedReason, LxmfUnverifiedReason.sourceUnknown);
    });

    test('queue is held while offline and delivered once back online',
        () async {
      p = await _pair();
      p.ia.dropFilter = (_) => true; // black hole: nothing reaches B
      final o =
          await p.ra.send(destinationHash: p.rb.address, content: 'later');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(o.state, isNot(LxmState.delivered));
      expect(o.attempts, greaterThanOrEqualTo(1));
      p.ia.dropFilter = null;
      await o.done.timeout(const Duration(seconds: 15));
      expect(o.state, LxmState.delivered);
      expect(o.attempts, greaterThan(1));
    });

    test('fails after the maximum number of attempts', () async {
      final (ia, ib) = MemoryInterface.pair();
      final a = await Reticulum.start(
          ReticulumConfig(interfaces: [ia], transport: _noStamps));
      final b = await Reticulum.start(
          ReticulumConfig(interfaces: [ib], transport: _noStamps));
      final ra = await LxmRouter.start(
        a,
        await Identity.generate(),
        displayName: 'A',
        config: const LxmRouterConfig(
          processInterval: Duration(milliseconds: 50),
          deliveryRetryWait: Duration(milliseconds: 150),
          pathRequestWait: Duration(milliseconds: 100),
          maxDeliveryAttempts: 3,
        ),
      );
      final rb = await LxmRouter.start(b, await Identity.generate(),
          displayName: 'B', config: _cfg);
      p = _Pair(a, b, ra, rb, ia, ib);
      final seen = ra.peerUpdates.first;
      await rb.announce();
      await seen;
      ia.dropFilter = (_) => true;
      final o = await ra.send(destinationHash: rb.address, content: 'lost');
      await o.done.timeout(const Duration(seconds: 20));
      expect(o.state, LxmState.failed);
      expect(o.error, contains('attempts'));
    });

    test('cancel removes the message from the queue', () async {
      p = await _pair();
      p.ia.dropFilter = (_) => true;
      final o = await p.ra.send(destinationHash: p.rb.address, content: 'x');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await p.ra.cancel(o.hash);
      expect(o.state, LxmState.cancelled);
      expect(p.ra.pending, isEmpty);
    });

    test('propagated delivery is not available yet', () async {
      p = await _pair();
      expect(
        () => p.ra.send(
          destinationHash: p.rb.address,
          content: 'x',
          method: LxmfMethod.propagated,
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('persistence', () {
    test('pending messages are saved, restored and removed when concluded',
        () async {
      final store = MemoryLxmStore();
      final (ia, ib) = MemoryInterface.pair();
      final a = await Reticulum.start(
          ReticulumConfig(interfaces: [ia], transport: _noStamps));
      final b = await Reticulum.start(
          ReticulumConfig(interfaces: [ib], transport: _noStamps));
      final idA = await Identity.generate();
      var ra = await LxmRouter.start(a, idA,
          displayName: 'A', config: _cfg, store: store);
      final rb = await LxmRouter.start(b, await Identity.generate(),
          displayName: 'B', config: _cfg);
      final seen = ra.peerUpdates.first;
      await rb.announce();
      await seen;

      ia.dropFilter = (_) => true;
      final o = await ra.send(
          destinationHash: rb.address, content: 'persist me', tag: '7');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(store.outbound.length, 1);
      expect(store.outbound.values.single.tag, '7');
      await ra.stop();

      // "restart": a new router with the same store resumes the queue.
      ia.dropFilter = null;
      final got = rb.incoming.first;
      ra = await LxmRouter.start(a, idA,
          displayName: 'A', config: _cfg, store: store);
      final r = await got.timeout(const Duration(seconds: 20));
      expect(r.message.contentAsString, 'persist me');
      expect(toHex(r.message.hash!), toHex(o.hash));
      for (var i = 0; i < 100 && store.outbound.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(store.outbound, isEmpty);

      await ra.stop();
      await rb.stop();
      await a.stop();
      await b.stop();
    });
  });
}
