@Tags(['integration'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import '../support/it_support.dart';
import '../support/python_peer.dart';

/// Device-group primitives (phase S1) against the Python reference
/// (RNS 1.6.1): silent destinations vs path requests, the monotonic announce
/// timebase vs a transport that orders announces by emission time, announce
/// stamp copy, and ratchet merge decrypting traffic the Python sender
/// encrypted to a sibling's ratchet.
void main() {
  if (findPython() == null) {
    test('python reference not available', () {}, skip: 'no tools/.venv');
    return;
  }

  const aspects = ['grp'];
  final nodes = <Reticulum>[];
  PythonPeer? peer;

  Future<Reticulum> dartNode(int port, {TransportConfig? config}) async {
    final r = await node(port, config: config);
    nodes.add(r);
    return r;
  }

  tearDown(() async {
    for (final n in nodes) {
      await n.stop();
    }
    nodes.clear();
    await peer?.stop();
    peer = null;
  });

  test('a silent destination never answers a Python path request', () async {
    peer = await PythonPeer.start();
    final x = await dartNode(peer!.port);
    final g = await Identity.generate();
    final d = await x.createDestination(g, 'kestrel', aspects);
    d.silent = true;

    peer!.send({'cmd': 'request_path', 'dest_hash': toHex(d.hash)});
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(peer!.has('announce_received'), isFalse,
        reason: 'silent device must not answer');
    expect(await x.announce(d), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(peer!.has('announce_received'), isFalse);

    // The announcer role moves here: the same request is now answered.
    d.silent = false;
    peer!.send({'cmd': 'request_path', 'dest_hash': toHex(d.hash)});
    final a = await peer!.waitFor('announce_received',
        where: (m) => m['dest_hash'] == toHex(d.hash));
    expect(a['path_response'], isTrue);
  });

  test('monotonic timebase lets a device with a slow clock take over the path',
      () async {
    // The peer is a transport node: it orders announces by emission time.
    peer = await PythonPeer.start(transport: true);
    final x = await dartNode(peer!.port);
    final y = await dartNode(peer!.port);
    final g = await Identity.generate();
    final dx = await x.createDestination(g, 'kestrel', aspects);
    final dy = await y.createDestination(g, 'kestrel', aspects);
    var gotX = 0, gotY = 0;
    dx.onPacket = (_, __) => gotX++;
    dy.onPacket = (_, __) => gotY++;

    Future<void> ping(String tag) async {
      peer!.send({
        'cmd': 'send_packet',
        'dest_hash': toHex(dx.hash),
        'aspects': ['kestrel', ...aspects],
        'data': tag,
      });
    }

    // X announces with the real clock and the group timebase.
    final tb = AnnounceTimebase();
    dx.announceTimebase = tb;
    await x.announce(dx);
    await peer!.waitFor('announce_received');
    await ping('61');
    await until(() => gotX == 1);

    // Y's clock is two minutes behind and it does not know the timebase:
    // the transport rejects its (older) announce, traffic stays with X.
    y.transport.clockSeconds =
        () => DateTime.now().millisecondsSinceEpoch ~/ 1000 - 120;
    await y.announce(dy);
    await Future<void>.delayed(const Duration(seconds: 1));
    await ping('62');
    await until(() => gotX == 2);
    expect(gotY, 0, reason: 'stale announce must not win without a timebase');

    // With the shared timebase the same slow-clock device takes over.
    dy.announceTimebase = AnnounceTimebase()..observe(tb.lastEmitted);
    await y.announce(dy);
    await Future<void>.delayed(const Duration(seconds: 1));
    await ping('63');
    await until(() => gotY == 1);
    expect(gotX, 2);
  });

  test('a copied announce stamp is accepted by Python without regeneration',
      () async {
    const cfg = TransportConfig(
      stampAnnounces: true,
      announceStampValue: 8,
      requiredAnnounceStampCost: 8,
      stampPathRequests: false,
    );
    peer = await PythonPeer.start(stamps: false, destCost: 8);
    final x = await dartNode(peer!.port, config: cfg);
    final y = await dartNode(peer!.port, config: cfg);
    final g = await Identity.generate();
    final dx = await x.createDestination(g, 'kestrel', aspects);
    final dy = await y.createDestination(g, 'kestrel', aspects);
    final tb = AnnounceTimebase();
    dx.announceTimebase = tb;

    final stamp = (await x.transport.ensureStamp(dx))!;
    expect(await y.transport.importStamp(dy, stamp), isTrue);
    dy.announceTimebase = AnnounceTimebase()..observe(tb.lastEmitted);

    final app = [0x61, 0x62, 0x63];
    expect(await y.announce(dy, appData: app), isTrue);
    expect(dy.stamp, stamp);
    final a = await peer!.waitFor('announce_received',
        where: (m) => m['dest_hash'] == toHex(dy.hash));
    // Python strips the ext payload only if it validated the stamp.
    expect(a['app_data'], '616263');
    expect(await y.transport.ensureStamp(dy), stamp);
  });

  test('merged ratchets decrypt a Python message encrypted to the sibling',
      () async {
    peer = await PythonPeer.start();
    final x = await dartNode(peer!.port);
    final g = await Identity.generate();
    final dx = await x.createDestination(g, 'kestrel', aspects, ratchets: true);
    final tb = AnnounceTimebase();
    dx.announceTimebase = tb;
    await x.announce(dx); // creates and announces ratchet R1
    await peer!.waitFor('announce_received');
    final r1 = dx.ratchets!.single;

    // Sibling Y: merges X's list, may not rotate, takes over as announcer.
    final y = await dartNode(peer!.port);
    final dy = await y.createDestination(g, 'kestrel', aspects, ratchets: true);
    expect(await dy.mergeRatchets(dx.exportRatchets()), 1);
    dy.ratchetRotationAllowed = false;
    dy.announceTimebase = AnnounceTimebase()..observe(tb.lastEmitted);
    final got = Completer<Uint8List>();
    dy.onPacket = (data, _) => got.complete(data);

    await x.stop();
    nodes.remove(x);
    await y.announce(dy);
    await peer!.waitFor('announce_received',
        where: (m) => m['dest_hash'] == toHex(dy.hash));
    expect(dy.ratchets!.single, r1, reason: 'same ratchet announced');

    peer!.send({
      'cmd': 'send_packet',
      'dest_hash': toHex(dy.hash),
      'aspects': ['kestrel', ...aspects],
      'data': '010203',
    });
    expect(await got.future.timeout(const Duration(seconds: 10)), [1, 2, 3]);
  });
}
