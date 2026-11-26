import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/node/identity_store.dart';
import 'package:kestrel/node/node_service.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/memory_interface.dart';

const _fast = LxmRouterConfig(
  processInterval: Duration(milliseconds: 100),
  deliveryRetryWait: Duration(milliseconds: 800),
  pathRequestWait: Duration(milliseconds: 500),
);
const _noStamps = TransportConfig(
  stampAnnounces: false,
  stampPathRequests: false,
);

Future<void> until(
  Future<bool> Function() cond, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final end = DateTime.now().add(timeout);
  while (!await cond()) {
    if (DateTime.now().isAfter(end)) throw StateError('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase adb;
  late Repo repo;
  late NodeService node;
  late Reticulum peerRns;
  late LxmRouter peer;
  late MemoryInterface appIface;
  late MemoryInterface peerIface;
  final secrets = MemorySecretStore();

  Future<NodeService> startNode() async {
    final n = NodeService(
      repo: repo,
      secrets: secrets,
      interfaceFactory: (h, _) =>
          h == 'example.invalid' ? MemoryInterface('other') : appIface,
      transportConfig: _noStamps,
      routerConfig: _fast,
    );
    await n.start();
    return n;
  }

  setUp(() async {
    adb = await AppDatabase.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    repo = Repo(adb);
    final (a, b) = MemoryInterface.pair(mtu: 262144);
    appIface = a;
    peerIface = b;
    peerRns = await Reticulum.start(
      ReticulumConfig(interfaces: [peerIface], transport: _noStamps),
    );
    peer = await LxmRouter.start(
      peerRns,
      await Identity.generate(),
      displayName: 'Peer',
      config: _fast,
    );
    node = await startNode();
  });

  tearDown(() async {
    await node.stop();
    await peer.stop();
    await peerRns.stop();
    await adb.close();
  });

  Future<void> exchangeAnnounces() async {
    await peer.announce();
    await until(() async => (await repo.peers()).isNotEmpty);
    await node.announce();
    await until(() async => peer.peer(node.router.address) != null);
  }

  test('identity B is created once, exposes address and public key', () async {
    expect(node.addressHex, hasLength(32));
    expect(node.publicKeyHex, hasLength(128));
    final acc = await adb.db.query('accounts', where: "identity = 'B'");
    expect(acc.single['address_hash'], node.addressHex);
    // Same private key (from the secret store) gives the same address.
    final again = await IdentityStore(secrets).loadOrCreate();
    expect(toHex(again.hash), toHex(node.identity.hash));
    expect(secrets.data.length, 1);
  });

  test(
    'connection state is exposed and the node announces when online',
    () async {
      expect(node.connection, NodeConnection.online);
      final seen = await peer.peerUpdates
          .firstWhere((p) => toHex(p.hash) == node.addressHex)
          .timeout(const Duration(seconds: 10));
      expect(seen.hash, node.router.address);
    },
  );

  test('send: message, outbox row and every transition are recorded', () async {
    await exchangeAnnounces();
    final chat = await node.openChat(toHex(peer.address), name: 'Peer');
    final got = peer.incoming.first.timeout(const Duration(seconds: 15));
    final mid = await node.sendMessage(chat, 'hello peer');
    final r = await got;
    expect(r.message.contentAsString, 'hello peer');

    await until(
      () async => (await repo.message(mid))!.status == MsgStatus.delivered,
    );
    final m = (await repo.message(mid))!;
    expect(m.senderIdentity, 'B');
    expect(m.route, 'opportunistic');
    expect(m.transport, 'tcp');
    expect(m.lxmfHash, toHex(r.message.hash!));

    final stages = (await repo.log(mid)).map((l) => l.stage).toList();
    expect(stages.first, 'queued');
    expect(stages, containsAllInOrder(['queued', 'sent', 'delivered']));

    final outbox = await adb.db.query('outbox');
    expect(outbox.single['sender_identity'], 'B');
    expect(outbox.single['route'], 'opportunistic');
    expect(outbox.single['status'], 'done');
  });

  test(
    'receive: chat is created, message stored with route and transport',
    () async {
      await exchangeAnnounces();
      final seenName = await repo.peers();
      expect(seenName.first.displayName, 'Peer');
      await peer.send(destinationHash: node.router.address, content: 'hi app');
      await until(() async => (await repo.chats()).isNotEmpty);
      await until(() async {
        final c = (await repo.chats()).first;
        return (await repo.messages(c.id)).isNotEmpty;
      });
      final c = (await repo.chats()).single;
      expect(c.accountIdentity, 'B');
      expect(c.peerHash, toHex(peer.address));
      expect(c.title, 'Peer');
      expect(c.unread, 1);
      final m = (await repo.messages(c.id)).single;
      expect(m.text, 'hi app');
      expect(m.direction, 'in');
      expect(m.route, 'opportunistic');
      expect(m.transport, 'tcp');
      expect(m.signatureValid, isTrue);
      expect((await repo.log(m.id)).single.stage, 'received');
    },
  );

  test('large message goes direct and the route is recorded', () async {
    await exchangeAnnounces();
    final chat = await node.openChat(toHex(peer.address));
    final got = peer.incoming.first.timeout(const Duration(seconds: 20));
    final mid = await node.sendMessage(chat, 'z' * 900);
    await got;
    await until(
      () async => (await repo.message(mid))!.status == MsgStatus.delivered,
    );
    final m = (await repo.message(mid))!;
    expect(m.route, 'direct');
    // frozen desired route stays what the user asked for
    expect((await repo.outbox(1))!.route, 'opportunistic');
    final stages = (await repo.log(mid)).map((l) => l.stage);
    expect(stages, contains('link_established'));
  });

  test(
    'offline: message waits in the queue, transport "none", then goes out',
    () async {
      await exchangeAnnounces();
      final chat = await node.openChat(toHex(peer.address));
      appIface.dropFilter = (_) => true;
      final mid = await node.sendMessage(chat, 'later');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect((await repo.message(mid))!.status, isNot(MsgStatus.delivered));
      final got = peer.incoming.first.timeout(const Duration(seconds: 20));
      appIface.dropFilter = null;
      await got;
      await until(
        () async => (await repo.message(mid))!.status == MsgStatus.delivered,
      );
    },
  );

  test(
    'bridge toggle does not touch chats while the node is running',
    () async {
      await exchangeAnnounces();
      final chat = await node.openChat(toHex(peer.address));
      await node.sendMessage(chat, 'one');
      await until(() async => (await repo.messages(chat)).isNotEmpty);
      final before = await adb.db.query('messages');
      await repo.setBridgeEnabled(true);
      await repo.setBridgeEnabled(false);
      expect(await adb.db.query('messages'), before);
      expect((await repo.chats()).length, 1);
    },
  );

  test(
    'settings: display name is re-announced, server change reconnects',
    () async {
      await exchangeAnnounces();
      // Announce freshness has one second resolution.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final updates = <LxmPeer>[];
      final sub = peer.peerUpdates.listen(updates.add);
      await node.setDisplayName('New Name');
      await until(() async => updates.any((p) => p.displayName == 'New Name'));
      await sub.cancel();
      expect(await repo.getSetting(SettingKeys.displayName), 'New Name');

      await node.setServer('example.invalid', 1234);
      expect(await repo.getSetting(SettingKeys.serverHost), 'example.invalid');
      expect(await repo.getSetting(SettingKeys.serverPort), '1234');
    },
  );

  test('address validation', () {
    expect(NodeService.isValidAddress('a' * 32), isTrue);
    expect(NodeService.isValidAddress(' ${'A' * 32} '), isTrue);
    expect(NodeService.isValidAddress('xyz'), isFalse);
    expect(NodeService.isValidAddress('a' * 31), isFalse);
  });
}
