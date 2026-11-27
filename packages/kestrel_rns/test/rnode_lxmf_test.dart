import 'dart:async';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import 'support/rnode_emulator.dart';

const _cfg = LxmRouterConfig(
  processInterval: Duration(milliseconds: 100),
  deliveryRetryWait: Duration(milliseconds: 800),
  pathRequestWait: Duration(milliseconds: 500),
);
const _noStamps = TransportConfig(
  stampAnnounces: false,
  stampPathRequests: false,
);

RNodeInterface _rnode(EmulatedRNode e, String l, {RNodeConfig? c}) =>
    RNodeInterface(
      label: l,
      opener: e.open,
      config: c ?? const RNodeConfig(),
      timing: const RNodeTiming.instant(),
    );

Future<void> _until(bool Function() cond, {int ms = 5000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('condition not reached');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late FakeAir air;
  late EmulatedRNode ea, eb;
  late RNodeInterface ia, ib;
  late Reticulum a, b;
  late LxmRouter ra, rb;

  setUp(() async {
    air = FakeAir();
    ea = EmulatedRNode(air: air);
    eb = EmulatedRNode(air: air);
    ia = _rnode(ea, 'A');
    ib = _rnode(eb, 'B');
    a = await Reticulum.start(
      ReticulumConfig(interfaces: [ia], transport: _noStamps),
    );
    b = await Reticulum.start(
      ReticulumConfig(interfaces: [ib], transport: _noStamps),
    );
    ra = await LxmRouter.start(
      a,
      await Identity.generate(),
      displayName: 'Alice',
      config: _cfg,
    );
    rb = await LxmRouter.start(
      b,
      await Identity.generate(),
      displayName: 'Bob',
      config: _cfg,
    );
    await _until(() => ia.online && ib.online);
    final seen = ra.peerUpdates.first;
    await rb.announce();
    await seen;
  });

  tearDown(() async {
    await ra.stop();
    await rb.stop();
    await a.stop();
    await b.stop();
    await ia.stop();
    await ib.stop();
  });

  test('two nodes exchange LXMF over two emulated RNodes', () async {
    final got = rb.incoming.first;
    final out = await ra.send(
      destinationHash: rb.address,
      content: 'hello over LoRa',
    );
    final rx = await got.timeout(const Duration(seconds: 10));
    expect(rx.message.contentAsString, 'hello over LoRa');
    // the router tells which interface carried it
    expect(rx.interface, same(ib));
    await out.done.timeout(const Duration(seconds: 10));
    expect(out.state, LxmState.delivered);
    expect(air.transmissions, greaterThan(1)); // announce + data + proof
    // RSSI/SNR of the last packet is reported
    expect(ib.status.rssi, -80);
    expect(ib.status.snr, 6.5);
  });

  test('both directions, announce path included', () async {
    final seenB = rb.peerUpdates.first;
    await ra.announce();
    await seenB;
    final gotA = ra.incoming.first;
    await rb.send(destinationHash: ra.address, content: 'ping');
    expect((await gotA.timeout(const Duration(seconds: 10))).interface, ia);
  });

  test('a large message is refused over the slow LoRa link', () async {
    final events = <LxmOutboundEvent>[];
    ra.outboundEvents.listen(events.add);
    final out = await ra.send(
      destinationHash: rb.address,
      content: 'x' * (40 * 1024),
      method: LxmfMethod.direct,
    );
    await out.done.timeout(const Duration(seconds: 20));
    expect(out.state, LxmState.failed);
    expect(events.map((e) => e.stage), contains('too_large_for_slow_link'));
    expect(events.last.interface, same(ia));
  });

  test('radios on different parameters do not hear each other', () async {
    await ib.reconfigure(const RNodeConfig(spreadingFactor: 9));
    final heard = <Object>[];
    rb.incoming.listen(heard.add);
    await ra.send(destinationHash: rb.address, content: 'unheard');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(heard, isEmpty);
    await ia.reconfigure(const RNodeConfig(spreadingFactor: 9));
    final got = rb.incoming.first;
    await ra.send(destinationHash: rb.address, content: 'now heard');
    expect(
      (await got.timeout(const Duration(seconds: 15))).message.contentAsString,
      'now heard',
    );
  });
}
