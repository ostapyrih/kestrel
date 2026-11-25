@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import '../support/it_support.dart';
import '../support/python_peer.dart';

/// LXMF router against the Python reference (`tools/it/lxmf_peer.py`,
/// LXMF 1.3.1).
void main() {
  if (findPython() == null) {
    test('python reference not available', () {}, skip: 'no tools/.venv');
    return;
  }

  const fast = LxmRouterConfig(
    processInterval: Duration(milliseconds: 200),
    deliveryRetryWait: Duration(seconds: 3),
    pathRequestWait: Duration(seconds: 2),
  );

  late PythonPeer peer;
  late Reticulum dart;
  late Identity me;
  late LxmRouter router;

  Future<void> setUpAll0({int? peerStampCost, double? myCost}) async {
    peer = await PythonPeer.startLxmf(stampCost: peerStampCost);
    dart = await node(peer.port);
    me = await Identity.generate();
    router = await LxmRouter.start(
      dart,
      me,
      displayName: 'Dart Node',
      config: myCost == null
          ? fast
          : LxmRouterConfig(
              processInterval: fast.processInterval,
              deliveryRetryWait: fast.deliveryRetryWait,
              pathRequestWait: fast.pathRequestWait,
              inboundStampCost: myCost,
            ),
    );
  }

  /// Both sides announce; returns python's view of dart's announce.
  Future<Map<String, Object?>> exchangeAnnounces() async {
    final seen = router.peerUpdates.first.timeout(const Duration(seconds: 10));
    peer.send({'cmd': 'announce'});
    await seen;
    await router.announce();
    return peer.waitFor('announce_received',
        where: (m) => m['dest_hash'] == toHex(router.address));
  }

  Future<LxmOutbound> sendToPeer(String text,
      {int method = LxmfMethod.opportunistic, Object? content}) async {
    final o = await router.send(
      destinationHash: fromHex(peer.destHash),
      content: content ?? text,
      method: method,
    );
    return o.done.timeout(const Duration(seconds: 40));
  }

  tearDown(() async {
    await router.stop();
    await dart.stop();
    await peer.stop();
  });

  test('announce app_data decodes in python (display name, no stamp)',
      () async {
    await setUpAll0();
    final a = await exchangeAnnounces();
    expect(a['display_name'], 'Dart Node');
    expect(a['stamp_cost'], isNull);
    final p =
        router.knownPeers.firstWhere((p) => toHex(p.hash) == peer.destHash);
    expect(p.displayName, 'Python Peer');
    expect(p.stampCost, isNull);
  });

  test('dart -> python opportunistic, delivery proof received', () async {
    await setUpAll0();
    await exchangeAnnounces();
    final states = <LxmState>[];
    final sub = router.outboundEvents.listen((e) => states.add(e.state));
    final o = await sendToPeer('hello from dart');
    await sub.cancel();
    expect(o.state, LxmState.delivered);
    expect(o.method, LxmfMethod.opportunistic);
    expect(states, contains(LxmState.sent));
    final r = await peer.waitFor('received');
    expect(r['content'], 'hello from dart');
    expect(r['source'], toHex(router.address));
    expect(r['signature_validated'], isTrue);
    expect(r['method'], LxmfMethod.opportunistic);
  });

  test('dart -> python direct over a link (packet)', () async {
    await setUpAll0();
    await exchangeAnnounces();
    final o = await sendToPeer('direct hello', method: LxmfMethod.direct);
    expect(o.state, LxmState.delivered);
    final r = await peer.waitFor('received');
    expect(r['content'], 'direct hello');
    expect(r['signature_validated'], isTrue);
    expect(r['method'], LxmfMethod.direct);
  });

  test('oversized opportunistic message upgrades to direct', () async {
    await setUpAll0();
    await exchangeAnnounces();
    final o = await sendToPeer('x' * 1000);
    expect(o.state, LxmState.delivered);
    expect(o.method, LxmfMethod.direct);
    final r = await peer.waitFor('received');
    expect(r['size'], 1000);
  });

  test('large message as a resource (dart -> python)', () async {
    await setUpAll0();
    await exchangeAnnounces();
    final text =
        utf8.decode(pseudoRandom(30000).map((b) => 0x61 + b % 26).toList());
    final o = await sendToPeer(text, method: LxmfMethod.direct);
    expect(o.state, LxmState.delivered);
    expect(o.message.representation, LxmfRepresentation.resource);
    final r =
        await peer.waitFor('received', timeout: const Duration(seconds: 40));
    expect(r['size'], 30000);
    expect(r['content_sha256'], toHex(sha256(utf8.encode(text))));
  });

  test('python -> dart opportunistic', () async {
    await setUpAll0();
    await exchangeAnnounces();
    final got = router.incoming.first.timeout(const Duration(seconds: 30));
    peer.send({
      'cmd': 'send',
      'dest_hash': toHex(router.address),
      'content': 'hi dart',
      'title': 'T'
    });
    final m = await got;
    expect(m.message.contentAsString, 'hi dart');
    expect(m.message.titleAsString, 'T');
    expect(m.message.signatureValidated, isTrue);
    expect(m.method, LxmfMethod.opportunistic);
    await peer.waitFor('delivered', timeout: const Duration(seconds: 30));
  });

  test('python -> dart direct, resource sized', () async {
    await setUpAll0();
    await exchangeAnnounces();
    final got = router.incoming.first.timeout(const Duration(seconds: 40));
    peer.send({
      'cmd': 'send',
      'dest_hash': toHex(router.address),
      'size': 20000,
      'method': 'direct'
    });
    final m = await got;
    expect(m.message.content.length, 20000);
    expect(m.message.signatureValidated, isTrue);
    expect(m.method, LxmfMethod.direct);
    await peer.waitFor('delivered', timeout: const Duration(seconds: 40));
  });

  test('python requiring a stamp: dart generates it, python accepts', () async {
    await setUpAll0(peerStampCost: 8);
    await exchangeAnnounces();
    expect(router.peer(fromHex(peer.destHash))!.stampCost, 8);
    final o = await sendToPeer('stamped');
    expect(o.state, LxmState.delivered);
    expect(o.message.stamp, isNotNull);
    final r = await peer.waitFor('received');
    expect(r['content'], 'stamped');
    expect(r['stamp_valid'], isTrue);
  });

  test('dart requiring a stamp: python generates, dart validates', () async {
    await setUpAll0(myCost: 8);
    final a = await exchangeAnnounces();
    expect(a['stamp_cost'], 8);
    final got = router.incoming.first.timeout(const Duration(seconds: 60));
    peer.send({
      'cmd': 'send',
      'dest_hash': toHex(router.address),
      'content': 'stamp me'
    });
    final m = await got;
    expect(m.stampValid, isTrue);
    expect(m.message.contentAsString, 'stamp me');
  });

  test('unknown destination: path request, then delivery after announce',
      () async {
    await setUpAll0();
    // No exchange yet: python has not announced; dart sends to an unknown hash.
    final o = await router.send(
      destinationHash: fromHex(peer.destHash),
      content: 'late',
    );
    await Future<void>.delayed(const Duration(milliseconds: 800));
    peer.send({'cmd': 'announce'});
    await router.announce();
    final done = await o.done.timeout(const Duration(seconds: 40));
    expect(done.state, LxmState.delivered);
  });
}
