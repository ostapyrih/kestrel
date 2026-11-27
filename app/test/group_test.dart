import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/group/group_service.dart';
import 'package:kestrel/node/identity_store.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final peerA = '11' * 16;
const t0 = 1700000000000;

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase adb;
  late Repo repo;
  late MemorySecretStore secrets;

  setUp(() async {
    adb = await AppDatabase.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    repo = Repo(adb);
    secrets = MemorySecretStore();
  });

  tearDown(() => adb.close());

  Future<int> count(String table) async => Sqflite.firstIntValue(
    await adb.db.rawQuery('SELECT COUNT(*) FROM $table'),
  )!;

  group('GroupService', () {
    test(
      'an existing identity B becomes G; the device key is separate',
      () async {
        final old = await IdentityStore(secrets).loadOrCreate();
        await repo.setSetting(SettingKeys.bridgePubkey, 'ab' * 64);
        final g = GroupService(repo: repo, secrets: secrets);
        await g.init();
        expect(g.groupIdentity.hash, old.hash, reason: 'the address is kept');
        expect(g.deviceIdentity.hash, isNot(old.hash));
        expect(
          g.legacyIdentity!.hash,
          old.hash,
          reason: 'the bridge still knows the device under B',
        );
        expect(g.devices.single.id, toHex(g.deviceIdentity.hash));
        expect(g.isGroup, isFalse);
        final g2 = GroupService(repo: repo, secrets: secrets);
        await g2.init();
        expect(g2.state.groupId, g.state.groupId);
        expect(g2.deviceIdentity.hash, g.deviceIdentity.hash);
      },
    );

    test('a fresh install has no legacy key', () async {
      final g = GroupService(repo: repo, secrets: secrets);
      await g.init();
      expect(g.legacyIdentity, isNull);
      expect(g.state.epoch, 1);
    });

    test('name and device rename persist', () async {
      final g = GroupService(repo: repo, secrets: secrets);
      await g.init();
      await g.setDisplayName(' Alice ');
      expect(g.displayName, 'Alice');
      expect(await repo.getSetting(SettingKeys.displayName), 'Alice');
      await g.renameDevice(g.ownId, 'Phone');
      expect(g.self.name, 'Phone');
      expect(await repo.getSetting(SettingKeys.deviceName), 'Phone');
      final g2 = GroupService(repo: repo, secrets: secrets);
      await g2.init();
      expect(g2.displayName, 'Alice');
      expect(g2.self.name, 'Phone');
    });

    test('removing a device rotates the key; own device stays', () async {
      final g = GroupService(repo: repo, secrets: secrets);
      await g.init();
      final other = GroupDevice.of(
        await Identity.generate(),
        name: 'Laptop',
        platform: 'windows',
      );
      g.state.devices.put(other);
      expect(g.isGroup, isTrue);
      expect(await g.removeDevice(g.ownId), isNull);
      final key1 = g.state.currentKey;
      final d = await g.removeDevice(other.id);
      expect(d!.removed, isTrue);
      expect(g.state.epoch, 2);
      expect(g.state.currentKey, isNot(key1));
      expect(g.isGroup, isFalse);
    });

    test('change address replaces G only', () async {
      final g = GroupService(repo: repo, secrets: secrets);
      await g.init();
      final before = g.groupIdentity.hash;
      final dev = g.deviceIdentity.hash;
      await g.replaceGroupIdentity(await Identity.generate());
      expect(g.groupIdentity.hash, isNot(before));
      expect(g.deviceIdentity.hash, dev);
      final g2 = GroupService(repo: repo, secrets: secrets);
      await g2.init();
      expect(g2.groupIdentity.hash, g.groupIdentity.hash);
    });

    test('address change notice round trips', () {
      final addr = 'ab' * 16;
      final t = addressChangeNotice(addr, name: 'Alice');
      expect(parseAddressChangeNotice(t), addr);
      expect(parseAddressChangeNotice('hello'), isNull);
    });
  });

  group('retiring the old identity when joining a group', () {
    test('own chats become read-only history labelled with the device',
        () async {
      final chat = await repo.findOrCreateChat('B', peerA, title: 'Alice');
      await repo.insertIncoming(
        identity: 'B',
        chatId: chat,
        lxmfHash: 'a1' * 16,
        text: 'hi',
        ts: DateTime.fromMillisecondsSinceEpoch(t0),
        route: 'direct',
        transport: 'tcp',
        signatureValid: true,
      );
      await repo.insertOutgoing(
        identity: 'B',
        chatId: chat,
        destinationHash: peerA,
        text: 'queued one',
        route: 'opportunistic',
        transport: 'none',
      );
      final old = 'cc' * 16;
      expect(await repo.retireOwnHistory(old, 'Old phone'), 1);
      expect(await repo.chats(accountIdentity: 'B'), isEmpty);
      expect(await count('messages'), 0);
      final remote = await repo.remoteChats();
      expect(remote.single.remoteDeviceName, 'Old phone');
      expect(remote.single.peerHash, peerA);
      final msgs = await repo.messages(remote.single.id);
      expect(msgs.map((m) => m.text), containsAll(['hi', 'queued one']));
      expect(
        msgs.firstWhere((m) => m.text == 'queued one').status,
        MsgStatus.failed,
        reason: 'unsent messages become failed history',
      );
      expect(await repo.isLegacyDevice(old), isTrue);
    });

    test('the bridge-off purge keeps retired histories', () async {
      final chat = await repo.findOrCreateChat('B', peerA);
      await repo.insertIncoming(
        identity: 'B',
        chatId: chat,
        lxmfHash: 'a2' * 16,
        text: 'keep',
        ts: DateTime.fromMillisecondsSinceEpoch(t0),
        route: 'direct',
        transport: 'tcp',
        signatureValid: true,
      );
      await repo.retireOwnHistory('dd' * 16, 'Old');
      await repo.purgeBridgeAccountData();
      expect(await count('vault_messages'), 1);
      expect(await count('vault_chats'), 1);
    });
  });

  group('applying synced messages', () {
    Map<Object?, Object?> rec(
      String hash,
      String text, {
      bool incoming = true,
      String? state,
      int ts = t0,
    }) => {
      'hash': hash,
      'peer': peerA,
      'text': text,
      'incoming': incoming,
      'ts': ts,
      'state': ?state,
    };

    test('forwarded inbound messages are stored once', () async {
      final h = 'e1' * 16;
      expect(await repo.applySyncedMessage(rec(h, 'hello')), isTrue);
      expect(await repo.applySyncedMessage(rec(h, 'hello')), isFalse);
      expect(await count('messages'), 1);
      final c = (await repo.chats(accountIdentity: 'B')).single;
      expect(c.unread, 1);
      expect(c.peerHash, peerA);
    });

    test('a message sent on a sibling is outgoing; state moves forward',
        () async {
      final h = 'e2' * 16;
      Future<bool> apply(String state) => repo.applySyncedMessage(
        rec(h, 'sent there', incoming: false, state: state),
      );
      expect(await apply(MsgStatus.sent), isTrue);
      expect(await apply(MsgStatus.delivered), isTrue);
      expect(await apply(MsgStatus.sent), isFalse, reason: 'never backwards');
      final chat = (await repo.chats(accountIdentity: 'B')).single;
      final m = (await repo.messages(chat.id)).single;
      expect(m.status, MsgStatus.delivered);
      expect(m.outgoing, isTrue);
      expect(await count('outbox'), 0, reason: 'nothing is sent again');
    });

    test('a group delete removes the chat and blocks stale records', () async {
      await repo.applySyncedMessage(rec('e3' * 16, 'one'));
      await repo.applySyncedMessage(rec('e4' * 16, 'two', ts: t0 + 1000));
      expect(await repo.applySyncedDelete(peerA, t0 + 1000), isTrue);
      expect(await count('messages'), 0);
      expect(await repo.chats(accountIdentity: 'B'), isEmpty);
      expect(await repo.applySyncedMessage(rec('e3' * 16, 'one')), isFalse);
      expect(
        await repo.applySyncedMessage(rec('e5' * 16, 'new', ts: t0 + 9000)),
        isTrue,
      );
      expect(await count('messages'), 1);
    });

    test('malformed records are refused', () async {
      expect(await repo.applySyncedMessage({'hash': 'x'}), isFalse);
      expect(
        await repo.applySyncedMessage({
          'hash': 'e6' * 16,
          'peer': 'zz',
          'text': 't',
        }),
        isFalse,
      );
    });
  });
}
