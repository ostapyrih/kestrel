@Tags(['integration'])
library;

import 'dart:async';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import '../support/it_support.dart';
import '../support/python_peer.dart';

/// Multi-device group: three Dart "devices" sharing one identity G meet a
/// Python LXMF peer through a Python transport node (all on loopback TCP).
const _fast = LxmRouterConfig(
  processInterval: Duration(milliseconds: 200),
  deliveryRetryWait: Duration(seconds: 3),
  pathRequestWait: Duration(seconds: 2),
  autoSync: false,
  propagationSyncInterval: null,
);

class Dev {
  Dev(this.name);
  final String name;
  late Reticulum rns;
  late Identity g;
  late Identity key;
  late GroupState state;
  late LxmRouter groupRouter;
  late LxmRouter deviceRouter;
  late DeviceSync sync;
  late GroupAnnouncer ann;
  final storage = MemoryStorage();
  final seen = <String>{};
  final texts = <String>[];
  final records = <SyncRecord>[];
  var stopped = false;

  String get id => toHex(key.hash);
  bool get announcing => ann.isAnnouncer;
  String get gHex => toHex(groupRouter.address);

  /// Starts routers, sync and election on top of [state] / [g] / [key].
  Future<void> run({List<RatchetEntry> ratchets = const []}) async {
    groupRouter =
        await LxmRouter.start(rns, g, displayName: 'Alice', config: _fast);
    if (ratchets.isNotEmpty) {
      await groupRouter.destination.mergeRatchets(ratchets);
    }
    groupRouter
      ..silent = true
      ..inboxSyncEnabled = false
      ..destination.ratchetRotationAllowed = false
      ..destination.announceTimebase = AnnounceTimebase();
    deviceRouter = await LxmRouter.start(rns, key, config: _fast);
    sync = DeviceSync(
      rns: rns,
      router: deviceRouter,
      deviceKey: key,
      state: state,
      store: KestrelSyncStore(storage),
      group: groupRouter.destination,
      gapDelay: const Duration(seconds: 1),
    );
    await sync.start();
    sync.rememberSiblings();
    sync.records.listen((r) {
      records.add(r);
      if (r.kind == SyncKind.messages) {
        final d = r.data! as Map;
        if (seen.add(d['hash']! as String)) texts.add(d['text']! as String);
      }
    });
    groupRouter.inboundPersister = (rx) async {
      final h = toHex(rx.message.hash!);
      if (!seen.add(h)) return;
      texts.add(rx.message.contentAsString);
      if (ann.isAnnouncer) {
        await sync.publish(SyncKind.messages, {
          'hash': h,
          'text': rx.message.contentAsString,
          'peer': toHex(rx.message.sourceHash),
          'incoming': true,
        });
      }
    };
    ann = GroupAnnouncer(
      rns: rns,
      deviceKey: key,
      state: state,
      internet: () => true,
      interval: const Duration(seconds: 1),
      deadAfter: const Duration(seconds: 4),
      startupGrace: const Duration(seconds: 2),
      onRole: (on) {
        groupRouter
          ..silent = !on
          ..inboxSyncEnabled = on
          ..destination.ratchetRotationAllowed = on;
        if (on) unawaited(sync.announceGroup(groupRouter));
      },
    );
    await ann.start();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await deviceRouter.announce();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await ann.announcePresence();
  }

  /// A message typed on this device: sent as G and synced to the siblings.
  Future<void> sendTo(String peer, String text) async {
    final o =
        await groupRouter.send(destinationHash: fromHex(peer), content: text);
    final h = toHex(o.hash);
    seen.add(h);
    texts.add(text);
    await sync.publish(SyncKind.messages,
        {'hash': h, 'text': text, 'peer': peer, 'incoming': false});
  }

  Future<void> kill() async {
    stopped = true;
    await ann.stop();
    await sync.stop();
    await groupRouter.stop();
    await deviceRouter.stop();
    await rns.stop();
  }
}

void main() {
  if (findPython() == null) {
    test('python reference not available', () {}, skip: 'no tools/.venv');
    return;
  }

  late PythonPeer p; // transport node + LXMF peer
  final devs = <Dev>[];

  Future<Dev> creator() async {
    final d = Dev('D1')..rns = await node(p.port);
    d.g = await Identity.generate();
    d.key = await Identity.generate();
    d.state = GroupState.create(
        GroupDevice.of(d.key, name: 'D1', platform: 'test'),
        displayName: 'Alice');
    devs.add(d);
    return d;
  }

  Future<Dev> joiner(Dev host, String name) async {
    final d = Dev(name)..rns = await node(p.port);
    d.key = await Identity.generate();
    final ph = await PairingHost.open(
      host.rns,
      host.key,
      hostName: host.name,
      confirm: (_) async => true,
      buildBundle: (dev) async => PairingBundle(
        groupPrivateKey: host.g.privateKey!,
        state: GroupState.decode(host.state.encode())!..devices.put(dev.copy()),
        ratchets: host.groupRouter.destination.exportRatchets(),
      ),
      onPaired: (dev) {
        host.state.devices.put(dev);
        unawaited(host.sync.publishDevices());
      },
    );
    // Python's ingress control holds announces of a young interface that
    // bursts (> ~3/s); space them out like the app does.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await ph.announce();
    final r = await PairingClient.join(
      d.rns,
      d.key,
      PairingInvite.parse(ph.invite.encode())!,
      name: name,
      platform: 'test',
      onCode: (_) {},
      confirm: (_) async => true,
      pathTimeout: const Duration(seconds: 15),
    );
    d.g = await Identity.fromPrivateKey(r.bundle.groupPrivateKey);
    d.state = r.bundle.state;
    devs.add(d);
    await d.run(ratchets: r.bundle.ratchets);
    return d;
  }

  Dev announcer() => devs.firstWhere((d) => !d.stopped && d.announcing);
  int announcers() => devs.where((d) => !d.stopped && d.announcing).length;

  setUp(() async {
    p = await PythonPeer.startLxmfRaw(
        transport: true, extraArgs: const ['--name', 'Peer']);
  });

  tearDown(() async {
    for (final d in devs) {
      if (!d.stopped) await d.kill();
    }
    devs.clear();
    await p.stop();
  });

  Future<void> peerSend(Dev to, String text) async {
    p.send({'cmd': 'ensure', 'dest_hash': to.gHex, 'timeout': 20});
    await p.waitFor('known');
    p.send({'cmd': 'send', 'dest_hash': to.gHex, 'content': text});
  }

  test('pairing, election, forwarding, handover, sent sync, deletions',
      () async {
    final d1 = await creator();
    await d1.run();
    final d2 = await joiner(d1, 'D2');
    final d3 = await joiner(d1, 'D3');

    // every device learned the full list (D2 through D1's devices record)
    await until(() => d2.state.devices.active.length == 3,
        timeout: const Duration(seconds: 30));
    await until(() => d3.state.devices.active.length == 3,
        timeout: const Duration(seconds: 30));

    // exactly one announcer, the lowest device id; the others stay silent
    final lowest = ([d1.id, d2.id, d3.id]..sort()).first;
    await until(() => announcers() == 1, timeout: const Duration(seconds: 30));
    expect(announcer().id, lowest);
    for (final d in devs.where((d) => d.id != lowest)) {
      expect(d.groupRouter.silent, isTrue);
      expect(d.groupRouter.inboxSyncEnabled, isFalse);
    }

    // a peer message reaches the announcer and is forwarded to the siblings
    await peerSend(announcer(), 'hello 1');
    await until(() => devs.every((d) => d.texts.contains('hello 1')),
        timeout: const Duration(seconds: 30));

    // a message typed on a non-announcer is sent as G and synced
    final typer = devs.firstWhere((d) => d.id != lowest);
    await typer.sendTo(p.destHash, 'from sibling');
    final rx = await p.waitFor('received',
        where: (m) => m['content'] == 'from sibling');
    expect(rx['source'], typer.gHex, reason: 'always sent as G');
    await until(() => devs.every((d) => d.texts.contains('from sibling')),
        timeout: const Duration(seconds: 30));

    // deletions and browser data travel as records
    final sender = devs.firstWhere((d) => d.id != lowest);
    await sender.sync
        .publish(SyncKind.deleteChat, {'peer': 'a' * 32, 'before_ts': 1.0});
    await sender.sync.publish(SyncKind.browser, {
      'ops': [
        {'op': 'bookmark.put', 'url': 'x', 'ts': 1}
      ]
    });
    for (final d in devs.where((d) => d != sender)) {
      await until(
          () =>
              d.records.any((r) => r.kind == SyncKind.deleteChat) &&
              d.records.any((r) => r.kind == SyncKind.browser),
          timeout: const Duration(seconds: 30));
    }

    // handover: the announcer dies; a message sent right then still arrives
    final old = announcer();
    await old.kill();
    await peerSend(devs.firstWhere((d) => !d.stopped), 'in flight');
    await until(() => announcers() == 1, timeout: const Duration(seconds: 40));
    expect(announcer().id, isNot(old.id));
    final alive = devs.where((d) => !d.stopped).toList();
    for (final d in alive) {
      await until(() => d.texts.contains('in flight'),
          timeout: const Duration(seconds: 60));
    }

    // nothing was delivered twice anywhere
    for (final d in devs) {
      expect(d.texts.where((t) => t == 'hello 1').length, 1, reason: d.name);
      expect(d.texts.where((t) => t == 'from sibling').length, 1,
          reason: d.name);
      expect(
          d.texts.where((t) => t == 'in flight').length, lessThanOrEqualTo(1),
          reason: d.name);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('removing a device rotates the key; the removed device is cut off',
      () async {
    final d1 = await creator();
    await d1.run();
    final d2 = await joiner(d1, 'D2');
    final d3 = await joiner(d1, 'D3');
    await until(() => d2.state.devices.active.length == 3,
        timeout: const Duration(seconds: 30));

    final removed = d3;
    await d1.sync.removeDevice(removed.id);
    await until(
        () => d2.state.epoch == 2 && !d2.state.devices.isActive(removed.id),
        timeout: const Duration(seconds: 40));
    expect(d2.state.currentKey, d1.state.currentKey);
    expect(removed.state.epoch, 1, reason: 'never received the new key');

    await d1.sync.publish(SyncKind.browser, {'ops': <Object?>[]});
    await until(() => d2.records.any((r) => r.kind == SyncKind.browser),
        timeout: const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(removed.records.any((r) => r.kind == SyncKind.browser), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
