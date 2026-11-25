import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import 'support/it_support.dart' show pseudoRandom, until;
import 'support/memory_interface.dart';

/// Network layer tests without sockets or Python: two [Reticulum] instances
/// joined by an in-memory interface (several instances per process, no
/// globals), plus the TCP client against a local server socket.
const _fast = TransportConfig(
  stampAnnounces: false,
  stampPathRequests: false,
  perHopTimeout: Duration(milliseconds: 300),
);

Future<(Reticulum, Reticulum, MemoryInterface, MemoryInterface)> pair({
  int mtu = 500,
  TransportConfig config = _fast,
  KestrelStorage? storageA,
}) async {
  final (ia, ib) = MemoryInterface.pair(mtu: mtu);
  final a = await Reticulum.start(ReticulumConfig(
    interfaces: [ia],
    transport: config,
    storage: storageA,
  ));
  final b = await Reticulum.start(ReticulumConfig(
    interfaces: [ib],
    transport: config,
  ));
  return (a, b, ia, ib);
}

Future<Destination> serverDest(Reticulum r, {String name = 'srv'}) async {
  final d = await r.createDestination(
    await Identity.generate(),
    'kestrel',
    ['unit', name],
  );
  d.registerRequestHandler(
    '/echo',
    (p, data, id, l, ri, at) => data,
    policy: RequestPolicy.all,
  );
  d.registerRequestHandler(
    '/big',
    (p, data, id, l, ri, at) => pseudoRandom(30000, seed: 'u'),
    policy: RequestPolicy.all,
  );
  d.registerRequestHandler(
    '/who',
    (p, data, id, l, ri, at) => ri?.hash,
    policy: RequestPolicy.all,
  );
  return d;
}

Future<Destination> learn(Reticulum client, Reticulum server, Destination d,
    {String name = 'srv'}) async {
  final heard = client.announces.first;
  await server.announce(d, appData: utf8.encode('x'));
  await heard.timeout(const Duration(seconds: 5));
  return client.recallDestination(d.hash, 'kestrel', ['unit', name])!;
}

void main() {
  group('announce handling', () {
    test('learn identity + path, dedup, newer announce replaces, older ignored',
        () async {
      final (a, b, _, _) = await pair();
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final d = await serverDest(a);
      final events = <AnnounceEvent>[];
      b.announces.listen(events.add);

      final p1 = await Announce.build(d,
          appData: [1], timestamp: 1700000000, random: _rb(1));
      final p2 = await Announce.build(d,
          appData: [2], timestamp: 1700000100, random: _rb(2));
      final old = await Announce.build(d,
          appData: [3], timestamp: 1699999000, random: _rb(3));
      final raw1 = p1.pack();
      final ib = b.interfaces.first;

      await b.transport.injectInbound(raw1, ib);
      await b.transport.injectInbound(raw1, ib); // exact duplicate
      await b.transport.injectInbound(p2.pack(), ib);
      await b.transport.injectInbound(old.pack(), ib);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events.length, 2, reason: 'duplicate and older announce ignored');
      expect(events[0].appData, [1]);
      expect(events[1].appData, [2]);
      // like Identity.remember(), any *valid* announce refreshes the stored
      // app_data, even one that does not change the path table
      expect(b.transport.recallAppData(d.hash), [3]);
      expect(b.transport.hopsTo(d.hash), 1);
      expect(toHex(b.transport.nextHop(d.hash)!), toHex(d.hash));
    });

    test('invalid announce (bad signature) is dropped', () async {
      final (a, b, _, _) = await pair();
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final d = await serverDest(a);
      final p = await Announce.build(d, appData: [1]);
      final raw = p.pack();
      raw[raw.length - 1] ^= 0xFF; // corrupt app data
      await b.transport.injectInbound(raw, b.interfaces.first);
      expect(b.transport.hasPath(d.hash), isFalse);
      expect(b.transport.recall(d.hash), isNull);
    });

    test('announce for own destination is not treated as a path', () async {
      final (a, b, _, _) = await pair();
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final d = await serverDest(a);
      final p = await Announce.build(d);
      await a.transport.injectInbound(p.pack(), a.interfaces.first);
      expect(a.transport.hasPath(d.hash), isFalse);
    });

    test('known destinations persist through storage', () async {
      final storage = MemoryStorage();
      final (a, b, _, _) = await pair(storageA: storage);
      final d = await serverDest(b);
      final heard = a.announces.first;
      await b.announce(d, appData: utf8.encode('persist'));
      await heard;
      await a.transport.flush();
      await a.stop();
      await b.stop();

      final (ia, _) = MemoryInterface.pair();
      final a2 = await Reticulum.start(ReticulumConfig(
        interfaces: [ia],
        storage: storage,
        transport: _fast,
      ));
      addTearDown(a2.stop);
      final k = a2.transport.recall(d.hash)!;
      expect(utf8.decode(k.appData!), 'persist');
      expect(
          a2.recallDestination(d.hash, 'kestrel', ['unit', 'srv']), isNotNull);
      expect(
          a2.recallDestination(d.hash, 'kestrel', ['unit', 'wrong']), isNull);
    });

    test('JsonFileStorage round trip + atomic overwrite', () async {
      final dir = await Directory.systemTemp.createTemp('kestrel_store');
      addTearDown(() => dir.delete(recursive: true));
      final s = JsonFileStorage(dir);
      expect(await s.read('a/b'), isNull);
      await s.write('a/b', {'x': 1, 'y': 'z'});
      await s.write('a/b', {'x': 2});
      expect(await s.read('a/b'), {'x': 2});
      await s.delete('a/b');
      expect(await s.read('a/b'), isNull);
      // known destination entry JSON round trip
      final k = KnownDestination(
        destinationHash: Uint8List(16),
        publicKey: Uint8List(64),
        timestamp: 1.5,
        packetHash: Uint8List(32),
        appData: Uint8List.fromList([1]),
        ratchet: Uint8List(32),
        stampValue: 9.5,
        linkCost: 12.5,
      );
      final k2 = KnownDestination.fromJson(
        json.decode(json.encode(k.toJson())) as Map<String, Object?>,
      );
      expect(k2.appData, [1]);
      expect(k2.stampValue, 9.5);
      expect(k2.ratchet!.length, 32);
    });
  });

  group('path requests', () {
    test('path request for a local destination is answered', () async {
      final (a, b, _, _) = await pair();
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final d = await serverDest(a);
      expect(b.transport.hasPath(d.hash), isFalse);
      final ok = await b.awaitPath(d.hash, timeout: const Duration(seconds: 5));
      expect(ok, isTrue);
      expect(b.transport.hopsTo(d.hash), 1);
    });

    test('duplicate path request tag is answered once; stamped PR accepted',
        () async {
      final (a, b, ia, _) = await pair(
        config: const TransportConfig(
          stampAnnounces: false,
          stampPathRequests: true,
          pathRequestStampValue: 6,
        ),
      );
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final d = await serverDest(a);
      await b.requestPath(d.hash);
      await until(() => b.transport.hasPath(d.hash));
      // replay the exact request frame at A: tag already seen
      final before = ia.sent.length;
      final bIface = b.interfaces.first as MemoryInterface;
      final req = bIface.sent.last;
      await a.transport.injectInbound(req, a.interfaces.first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(ia.sent.length, before);
      // frame layout: 16 dest + 16 transport id + 16 tag + ext(2+14)
      final p = Packet.unpack(req);
      expect(p.data.length, 16 * 3 + 2 + 14);
      expect(p.data[48], 0xC1);
    });

    test('mismatched path table entries expire', () async {
      final (a, b, _, _) = await pair(
        config: const TransportConfig(
          stampAnnounces: false,
          pathTimeout: Duration(milliseconds: 50),
        ),
      );
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final d = await serverDest(a);
      await learn(b, a, d);
      expect(b.transport.hasPath(d.hash), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(b.transport.hasPath(d.hash), isFalse);
    });
  });

  group('packets, proofs and receipts', () {
    test('proved packet: receipt delivered; no proof: receipt fails', () async {
      final (a, b, _, _) = await pair();
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final d = await serverDest(a);
      final got = Completer<Uint8List>();
      d.onPacket = (data, p) => got.complete(data);
      final out = await learn(b, a, d);

      // no proof strategy yet -> timeout
      final r1 = await b.send(out, [1, 2, 3]);
      expect(await got.future, [1, 2, 3]);
      r1!.timeout = 0.3;
      final done1 = await r1.done.timeout(const Duration(seconds: 5));
      expect(done1.status, ReceiptStatus.failed);

      d.proofStrategy = ProofStrategy.all;
      final r2 = await b.send(out, [4]);
      expect((await r2!.done.timeout(const Duration(seconds: 5))).status,
          ReceiptStatus.delivered);

      // app-decided proofs
      d.proofStrategy = ProofStrategy.app;
      d.onProofRequested = (p) => false;
      final r3 = await b.send(out, [5]);
      r3!.timeout = 0.3;
      expect((await r3.done.timeout(const Duration(seconds: 5))).status,
          ReceiptStatus.failed);
    });

    test('forged proof is rejected', () async {
      final (a, b, ia, _) = await pair();
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final d = await serverDest(a);
      d.proofStrategy = ProofStrategy.all;
      final out = await learn(b, a, d);
      // swallow the genuine proof, then forge one with another key
      ia.dropFilter =
          (raw) => Packet.unpack(raw).packetType == Packet.typeProof;
      final r = await b.send(out, [9]);
      r!.timeout = 0.4;
      final mallory = await Identity.generate();
      final sig = await mallory.sign(r.hash);
      final proof = Packet(
        destinationHash: r.truncatedHash,
        data: sig,
        packetType: Packet.typeProof,
        destinationType: DestinationType.single,
      );
      await b.transport.injectInbound(proof.pack(), b.interfaces.first);
      expect((await r.done.timeout(const Duration(seconds: 5))).status,
          ReceiptStatus.failed);
    });

    test('PLAIN destination delivers cleartext broadcast', () async {
      final (a, b, _, _) = await pair();
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final pa = a.createPlainDestination('kestrel', ['plain']);
      final got = Completer<Uint8List>();
      pa.onPacket = (d, p) => got.complete(d);
      final out = Destination.plain('kestrel', ['plain'],
          direction: DestinationDirection.outbound);
      await b.send(out, [7, 7]);
      expect(await got.future.timeout(const Duration(seconds: 5)), [7, 7]);
    });
  });

  group('links', () {
    test('establish, identify, request, resource response, teardown', () async {
      final (a, b, _, _) = await pair();
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final d = await serverDest(a);
      final inbound = Completer<Link>();
      d.onLinkEstablished = (l) => inbound.complete(l as Link);
      final out = await learn(b, a, d);
      final link = await b.connect(out);
      final srv = await inbound.future.timeout(const Duration(seconds: 5));
      await until(() => srv.isActive);
      expect(link.mtu, 500);
      expect(link.mdu, 431);
      expect(toHex(link.linkId), toHex(srv.linkId));

      final me = await Identity.generate();
      final identified = Completer<Identity>();
      srv.onRemoteIdentified = (_, i) => identified.complete(i);
      await link.identify(me);
      expect(toHex((await identified.future).hash), toHex(me.hash));

      final who = await link.request('/who');
      await who!.done;
      expect(toHex(who.response! as Uint8List), toHex(me.hash));

      final big = await link.request('/big');
      await big!.done.timeout(const Duration(seconds: 20));
      expect(big.response, pseudoRandom(30000, seed: 'u'));
      expect(big.progress, 1.0);

      await link.teardown();
      await srv.closed.timeout(const Duration(seconds: 5));
      expect(srv.teardownReason, TeardownReason.initiatorClosed);
    });

    test('MTU discovery: signalled and confirmed MTU', () async {
      final (a, b, _, _) = await pair(mtu: 8192);
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final d = await serverDest(a);
      final out = await learn(b, a, d);
      final link = await b.connect(out);
      expect(link.mtu, 8192);
      final rr = await link.request('/big');
      await rr!.done.timeout(const Duration(seconds: 10));
      expect(rr.response, pseudoRandom(30000, seed: 'u'));
    });

    test('link request with no peer times out', () async {
      final (a, b, ia, _) = await pair();
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final d = await serverDest(a);
      final out = await learn(b, a, d);
      ia.dropFilter = (_) => true; // black-hole A's outbound (the proof)
      final link = await Link.initiate(b.transport, out);
      await expectLater(
        link.established.timeout(const Duration(seconds: 8)),
        throwsA(isA<StateError>()),
      );
      expect(link.teardownReason, TeardownReason.timeout);
    });

    test('responder ignores a LRPROOF with a bad signature', () async {
      final (a, b, ia, _) = await pair();
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final d = await serverDest(a);
      final out = await learn(b, a, d);
      // corrupt the link proof in flight
      ia.dropFilter = (raw) => Packet.unpack(raw).context == Packet.lrProof;
      final link = await Link.initiate(b.transport, out);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final proofFrame = ia.sent.firstWhere(
        (r) => Packet.unpack(r).context == Packet.lrProof,
      );
      final bad = Uint8List.fromList(proofFrame);
      bad[bad.length - 40] ^= 0xFF;
      await b.transport.injectInbound(bad, b.interfaces.first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(link.status, isNot(LinkStatus.active));
      await link.teardown();
    });

    test('resources both ways incl. compression and size limit', () async {
      final (a, b, _, _) = await pair(
        config: const TransportConfig(
          stampAnnounces: false,
          stampPathRequests: false,
          maxResourceSize: 100000,
        ),
      );
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final d = await serverDest(a);
      final inbound = Completer<Link>();
      d.onLinkEstablished = (l) => inbound.complete(l as Link);
      final out = await learn(b, a, d);
      final link = await b.connect(out);
      final srv = await inbound.future;
      await until(() => srv.isActive);
      srv.resourceStrategy = ResourceStrategy.all;

      final received = Completer<Resource>();
      srv.onResourceConcluded = (r) {
        if (!received.isCompleted) received.complete(r);
      };
      final data = Uint8List.fromList(List.filled(40000, 0x42));
      final done = Completer<Resource>();
      var progress = 0.0;
      await link.sendResource(
        data,
        callback: done.complete,
        progressCallback: (r) => progress = r.progress,
      );
      final r = await received.future.timeout(const Duration(seconds: 20));
      expect(r.data, data);
      expect(r.compressed, isTrue);
      expect(r.size, lessThan(2000)); // highly compressible
      expect((await done.future.timeout(const Duration(seconds: 10))).status,
          ResourceStatus.complete);
      expect(progress, greaterThanOrEqualTo(0));

      // exceeds maxResourceSize (200 KB incompressible) -> rejected
      final big = pseudoRandom(200000, seed: 'big');
      final rejected = Completer<Resource>();
      await link.sendResource(big, callback: rejected.complete);
      expect(
          (await rejected.future.timeout(const Duration(seconds: 10))).status,
          ResourceStatus.rejected);

      // srv strategy none -> ignore (no accept), sender times out later;
      // here: app strategy rejecting
      srv.resourceStrategy = ResourceStrategy.app;
      srv.onResourceAdvertised = (adv) => false;
      final rej2 = Completer<Resource>();
      await link.sendResource(data, callback: rej2.complete);
      expect((await rej2.future.timeout(const Duration(seconds: 10))).status,
          ResourceStatus.rejected);
    });

    test('request handler policies: none and list', () async {
      final (a, b, _, _) = await pair();
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final d = await serverDest(a);
      final allowed = await Identity.generate();
      d.registerRequestHandler(
        '/private',
        (p, data, id, l, ri, at) => 'secret',
        policy: RequestPolicy.list,
        allowedList: [allowed.hash],
      );
      d.registerRequestHandler(
        '/none',
        (p, data, id, l, ri, at) => 'x',
      );
      final out = await learn(b, a, d);
      final link = await b.connect(out);

      final r0 = await link.request('/none', timeout: 0.5);
      expect((await r0!.done).status, RequestStatus.failed);
      final r1 = await link.request('/private', timeout: 0.5);
      expect((await r1!.done).status, RequestStatus.failed);
      await link.identify(allowed);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final r2 = await link.request('/private');
      expect((await r2!.done).response, 'secret');
      expect(d.deregisterRequestHandler('/private'), isTrue);
    });

    test('several independent instances in one process', () async {
      final nodes = <Reticulum>[];
      for (var i = 0; i < 3; i++) {
        final (a, b, _, _) = await pair();
        nodes
          ..add(a)
          ..add(b);
      }
      addTearDown(() async {
        for (final n in nodes) {
          await n.stop();
        }
      });
      expect(
          {for (final n in nodes) toHex(n.transport.instanceHash)}.length, 6);
    });
  });

  group('destinations: ratchets and stamps', () {
    test('ratchets rotate, persist, and decrypt', () async {
      final storage = MemoryStorage();
      final (ia, _) = MemoryInterface.pair();
      final r = await Reticulum.start(ReticulumConfig(
        interfaces: [ia],
        storage: storage,
        transport: _fast,
      ));
      addTearDown(r.stop);
      final id = await Identity.generate();
      final d =
          await r.createDestination(id, 'kestrel', ['rat'], ratchets: true);
      final pub1 = await d.rotateRatchets(nowSeconds: 1000);
      final pub2 = await d.rotateRatchets(nowSeconds: 1000 + 10); // too soon
      expect(pub2, pub1);
      final pub3 = await d.rotateRatchets(nowSeconds: 1000 + 31 * 60);
      expect(pub3, isNot(pub1));
      expect(d.ratchets!.length, 2);
      final stored = await storage.read('ratchets/${toHex(d.hash)}');
      expect((stored!['ratchets']! as List<Object?>).length, 2);

      // encrypted with the newest ratchet decrypts via destination ratchets
      final out = Destination.single(
        Identity.fromPublicKey(id.publicKey),
        'kestrel',
        ['rat'],
        direction: DestinationDirection.outbound,
      );
      final ct = await out.encrypt([1, 2, 3], ratchet: pub3);
      expect(await d.decrypt(ct, ratchets: d.ratchets), [1, 2, 3]);
      d.enforceRatchets = true;
      final plainKeyCt = await out.encrypt([1, 2, 3]);
      expect(
        await d.decrypt(plainKeyCt,
            ratchets: d.ratchets, enforceRatchets: true),
        isNull,
      );
    });

    test('announce stamp is generated once, persisted and reused', () async {
      final storage = MemoryStorage();
      final (ia, _) = MemoryInterface.pair();
      final r = await Reticulum.start(ReticulumConfig(
        interfaces: [ia],
        storage: storage,
        transport: const TransportConfig(
          stampAnnounces: true,
          announceStampValue: 8,
          stampPathRequests: false,
        ),
      ));
      addTearDown(r.stop);
      final d = await r.createDestination(
        await Identity.generate(),
        'kestrel',
        ['stampme'],
      );
      final s1 = (await r.transport.ensureStamp(d))!;
      final persisted = await storage.read('stamp/${toHex(d.hash)}');
      expect(persisted, isNotNull);
      d.stamp = null; // force reload from storage
      final s2 = (await r.transport.ensureStamp(d))!;
      expect(s2, s1);
      final wb = Stamps.destinationMaterial(
        d.hash,
        d.identity!.publicKey,
        d.nameHash,
      );
      expect(Stamps.isValid(s1, 8, wb), isTrue);

      // announce frame carries the ext payload; receiver validates it
      final (ia2, ib2) = MemoryInterface.pair();
      final tx = await Reticulum.start(ReticulumConfig(
        interfaces: [ia2],
        transport: const TransportConfig(
          stampAnnounces: true,
          announceStampValue: 8,
          stampPathRequests: false,
        ),
      ));
      final rx = await Reticulum.start(ReticulumConfig(
        interfaces: [ib2],
        transport: const TransportConfig(
          stampAnnounces: false,
          requiredAnnounceStampCost: 8,
        ),
      ));
      addTearDown(() async {
        await tx.stop();
        await rx.stop();
      });
      final d2 = await tx.createDestination(
        await Identity.generate(),
        'kestrel',
        ['stamped2'],
      );
      final heard = rx.announces.first;
      await tx.announce(d2, appData: [1, 2]);
      final ev = await heard.timeout(const Duration(seconds: 30));
      expect(ev.announce.stamp, isNotNull);
      expect(ev.announce.stampValue, greaterThanOrEqualTo(8));
      expect(ev.appData, [1, 2]);
      expect(ev.announce.linkCost, 12.5);
      expect(rx.transport.recall(d2.hash)!.linkCost, 12.5);
    });

    test('enforced stamps drop unstamped announces', () async {
      final (a, b, _, _) = await pair(
        config: const TransportConfig(
          stampAnnounces: false,
          enforceAnnounceStamps: true,
          stampPathRequests: false,
        ),
      );
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final d = await serverDest(a);
      await a.announce(d);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(b.transport.hasPath(d.hash), isFalse);
    });
  });

  group('TcpClientInterface', () {
    test('HDLC framing both ways, state stream, reconnect with backoff',
        () async {
      var server = await ServerSocket.bind('127.0.0.1', 0);
      final port = server.port;
      final conns = <Socket>[];
      final rxFrames = <Uint8List>[];
      final dec = HdlcDecoder();
      void accept(ServerSocket s) => s.listen((c) {
            conns.add(c);
            c.listen((d) => rxFrames.addAll(dec.feed(d)), onError: (_) {});
          });
      accept(server);

      final iface = TcpClientInterface(
        host: '127.0.0.1',
        port: port,
        reconnectDelay: const Duration(milliseconds: 100),
        maxReconnectDelay: const Duration(milliseconds: 400),
      );
      final states = <InterfaceState>[];
      iface.stateChanges.listen(states.add);
      final frames = <Uint8List>[];
      iface.received.listen(frames.add);
      expect(iface.hwMtu, 262144);
      expect(iface.bitrate, 10000000);
      await iface.start();
      await until(() => iface.online);

      // inbound: server sends two frames in odd chunking
      final pkt = Packet(
        destinationHash: Uint8List(16),
        data: Uint8List.fromList(List.generate(40, (i) => i == 3 ? 0x7E : i)),
      ).pack();
      final wire = Hdlc.frame(pkt);
      conns.first.add(wire.sublist(0, 7));
      await conns.first.flush();
      conns.first.add([...wire.sublist(7), ...wire]);
      await until(() => frames.length == 2);
      expect(frames.first, pkt);

      // outbound
      expect(await iface.send(pkt), isTrue);
      await until(() => rxFrames.isNotEmpty);
      expect(rxFrames.first, pkt);

      // server goes away -> offline -> comes back -> online again
      await server.close();
      for (final c in conns) {
        c.destroy();
      }
      await until(() => !iface.online);
      expect(await iface.send(pkt), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      server = await ServerSocket.bind('127.0.0.1', port);
      accept(server);
      await until(() => iface.online, timeout: const Duration(seconds: 10));
      expect(
          states,
          containsAllInOrder([
            InterfaceState.connecting,
            InterfaceState.online,
            InterfaceState.offline,
            InterfaceState.online,
          ]));
      await iface.stop();
      await server.close();
      expect(iface.state, InterfaceState.offline);
    });

    test('stops retrying after maxReconnectTries', () async {
      final probe = await ServerSocket.bind('127.0.0.1', 0);
      final port = probe.port;
      await probe.close();
      var attempts = 0;
      final iface = TcpClientInterface(
        host: '127.0.0.1',
        port: port,
        reconnectDelay: const Duration(milliseconds: 20),
        maxReconnectTries: 3,
        connector: (h, p, t) {
          attempts++;
          throw const SocketException('refused');
        },
      );
      await iface.start();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(attempts, 4); // initial + 3 retries
      expect(iface.online, isFalse);
      await iface.stop();
    });
  });
}

RandomBytes _rb(int seed) =>
    (n) => Uint8List.fromList(List.generate(n, (i) => (seed * 31 + i) & 0xFF));
