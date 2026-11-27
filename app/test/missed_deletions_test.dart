import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/bridge/bridge_service.dart';
import 'package:kestrel/bridge/codec.dart';
import 'package:kestrel/node/identity_store.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_bridge_api.dart';
import 'vault_service_test.dart' show VaultServer, devMap;

final me = '0a' * 16;
final devY = 'bb' * 16;
final peer = '11' * 16; // A chat deleted on another device
final peerKeep = '33' * 16; // A chat that stays
final peerB = '22' * 16; // vault / B chat

const t0 = 1700000000000; // ms

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase adb;
  late Repo repo;
  late FakeBridgeApi api;
  late BridgeService svc;
  late Identity mine;
  late Identity theirs;
  late VaultServer server;
  final syncCursors = <int>[];

  Future<int> count(String table, [String? where]) async =>
      Sqflite.firstIntValue(
        await adb.db.rawQuery(
          'SELECT COUNT(*) FROM $table${where == null ? '' : ' WHERE $where'}',
        ),
      )!;

  Future<void> addA(String peerHash, String hash, int tsMs, int id) async {
    final chat = await repo.findOrCreateChat('A', peerHash, title: 'P');
    await adb.db.insert('messages', {
      'account_id': await repo.accountId('A'),
      'chat_id': chat,
      'direction': 'in',
      'lxmf_hash': hash,
      'text': 't',
      'ts': tsMs,
      'sender_identity': 'A',
      'transport': 'tcp',
      'status': 'received',
      'bridge_id': id,
    });
  }

  Future<void> deliver(
    String dev,
    int seq,
    String kind,
    Map<String, Object?> data,
  ) async {
    final chain = svc.vault.keys.chain;
    final id = toHex(secureRandomBytes(16));
    final ct = await VaultCrypto.encryptBlob(
      groupKey: chain[1]!,
      blobId: id,
      deviceId: dev,
      seq: seq,
      keyEpoch: 1,
      kind: kind,
      ts: 1700000000.0,
      data: data,
    );
    server.blobs.add({
      'vcursor': server.blobs.length + 1,
      'blob_id': id,
      'device_id': dev,
      'seq': seq,
      'key_epoch': 1,
      'size': ct.length,
      'ciphertext': ct,
    });
    await svc.vault.onBlobPush();
    await svc.vault.whenIdle();
  }

  Map<String, Object?> rec(String hash, int tsMs, {String text = 'old'}) => {
    'hash': hash,
    'peer': peerB,
    'peer_name': 'Peer',
    'incoming': false,
    'title': '',
    'text': text,
    'ts': tsMs / 1000,
    'rts': 1700000001.0,
    'state': 'sent',
    'method': 'direct',
    'transport': 'tcp',
    'error': null,
  };

  Future<void> connect() async {
    api.connect(helloFor(me, stateId: 'st1'));
    await svc.flushEvents();
    await svc.vault.whenIdle();
  }

  /// A bridge that keeps the deletion of [peer] as a tombstone with change
  /// value 5 (current counter 9) and, like a stale MeshChatX page, still
  /// hands out old messages for any peer.
  void bridge({List<Map<String, Object?>> lxmf = const []}) {
    api.handlers['/sync_chats'] = (a) {
      final c = a['cursor'] as int;
      syncCursors.add(c);
      return {
        'state_id': 'st1',
        'cursor': 9,
        'reset': false,
        'more': false,
        'lxmf': c < 9 ? lxmf : <Object?>[],
        'rrc': <Object?>[],
        'deleted': c < 5
            ? [
                {'peer': peer, 'before_ts': (t0 + 1000) / 1000},
              ]
            : <Object?>[],
      };
    };
    api.handlers['/get_messages'] = (a) => {
      'peer': a['peer'],
      'has_more': false,
      'gap': false,
      'messages': [
        msgMap(1, 'a1' * 16, ts: t0 / 1000),
        msgMap(2, 'a2' * 16, ts: (t0 + 1000) / 1000),
      ],
    };
    api.handlers['/list_rooms'] = (a) => {'hubs': []};
  }

  setUp(() async {
    adb = await AppDatabase.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    repo = Repo(adb);
    api = FakeBridgeApi(vaultStubs: false);
    mine = await Identity.generate();
    theirs = await Identity.generate();
    syncCursors.clear();
    server = VaultServer(api, {
      me: (devMap(me, mine, name: 'This'), mine),
      devY: (devMap(devY, theirs, name: 'Phone'), theirs),
    })..install();
    bridge();
    svc = BridgeService(
      repo: repo,
      ownDeviceId: () => me,
      identity: () => mine,
      apiFactory: (_, _) => api,
      secrets: MemorySecretStore(),
      sendAsB: (c, t) async => 0,
    );
    await svc.configure('bridge public key: ${'cd' * 64}');
  });

  tearDown(() async {
    await svc.stop();
    await adb.close();
  });

  test('upgrade from an app that skipped deletions: A and vault chats that '
      'were deleted elsewhere disappear, kept chats stay', () async {
    // a normal first run so that the vault holds the deletion history
    await connect();
    await deliver(devY, 1, 'messages', {
      'records': [rec('y1', t0), rec('y2', t0 + 1000)],
    });
    await deliver(devY, 2, 'delete_chat', {
      'peer': peerB,
      'before_ts': (t0 + 1000) / 1000,
    });
    expect(await repo.remoteChats(), isEmpty);

    // the state an old app left behind: the chats are still here, cursors
    // point past every deletion, no tombstones, stale sync version
    await addA(peer, 'a1' * 16, t0, 1);
    await addA(peer, 'a2' * 16, t0 + 1000, 2);
    await addA(peerKeep, 'k1' * 16, t0, 3);
    await adb.db.delete('vault_tombstones');
    await adb.db.delete('a_tombstones');
    await svc.vault.store.applyRecords(devY, [rec('y1', t0)]);
    expect(await repo.remoteChats(), hasLength(1));
    await adb.db.delete(
      'settings',
      where: 'key = ?',
      whereArgs: [SettingKeys.syncSemanticsVersion],
    );
    await svc.store.saveCursor(9, 'st1');
    await svc.vault.store.saveCursor(server.blobs.length);
    await svc.vault.store.setSeen(devY, 2);
    syncCursors.clear();

    // the upgraded app connects
    await connect();

    expect(syncCursors.first, 0); // the change stream was read again
    expect(await svc.store.chatIdForPeer(peer), isNull);
    expect(await svc.store.chatIdForPeer(peerKeep), isNotNull);
    expect(await repo.remoteChats(), isEmpty);
    expect(await repo.getSetting(SettingKeys.syncSemanticsVersion), '1');

    // the next start does not repeat the catch-up
    syncCursors.clear();
    await connect();
    expect(syncCursors.single, 9);
  });

  test(
    'A tombstone is stored even without the chat; old messages are '
    'refused afterwards (get_messages, sync, push), newer ones kept',
    () async {
      expect(await repo.applyChatDeleted(peer, (t0 + 1000) / 1000), isFalse);
      expect(await repo.aTombstone(peer), t0 + 1000);

      // the conversation list still names the chat and old pages are served:
      // nothing comes back and no empty chat is left
      bridge(lxmf: [convMap(peer)]);
      await connect();
      expect(await svc.store.chatIdForPeer(peer), isNull);
      expect(await count('messages', "lxmf_hash = '${'a1' * 16}'"), 0);

      // a message after the deletion starts a fresh chat
      final chat = await svc.store.ensureChat(peer);
      await svc.store.upsertMessage(
        chat,
        BridgeMessage.fromMap(msgMap(7, 'a7' * 16, ts: (t0 + 9000) / 1000)),
      );
      expect(await repo.messages(chat), hasLength(1));
      // an old one is still refused
      final dropped = await svc.store.upsertMessage(
        chat,
        BridgeMessage.fromMap(msgMap(1, 'a1' * 16, ts: t0 / 1000)),
      );
      expect(dropped, -1);
      expect(await repo.messages(chat), hasLength(1));
    },
  );

  test('the A tombstone survives turning the bridge off', () async {
    await repo.applyChatDeleted(peer, (t0 + 1000) / 1000);
    await repo.purgeBridgeAccountData();
    expect(await repo.aTombstone(peer), t0 + 1000);
  });

  test('vault: delete_chat arriving BEFORE the chat blobs still wins '
      '(out of order); newer messages survive', () async {
    await connect();
    await deliver(devY, 1, 'delete_chat', {
      'peer': peerB,
      'before_ts': (t0 + 1000) / 1000,
    });
    expect(await count('vault_tombstones'), 1);
    await deliver(devY, 2, 'messages', {
      'records': [
        rec('y1', t0),
        rec('y2', t0 + 1000),
        rec('y3', t0 + 5000, text: 'newer'),
      ],
    });
    final c = (await repo.remoteChats()).single;
    expect((await repo.messages(c.id)).map((m) => m.text), ['newer']);
  });

  test('owner_device deletion on the receiving device holds after a full '
      'resync', () async {
    await connect();
    final chat = await repo.findOrCreateChat('B', peerB, title: 'P');
    for (final (i, ts) in [t0, t0 + 2000, t0 + 90000].indexed) {
      await repo.insertIncoming(
        identity: 'B',
        chatId: chat,
        lxmfHash: 'b$i',
        text: i == 2 ? 'newer' : 'old',
        ts: DateTime.fromMillisecondsSinceEpoch(ts),
        route: 'direct',
        transport: 'tcp',
        signatureValid: true,
      );
    }
    await deliver(devY, 1, 'delete_chat', {
      'peer': peerB,
      'owner_device': me,
      'before_ts': (t0 + 5000) / 1000,
    });
    Future<List<String>> texts() async => [
      for (final m in await repo.messages(chat)) m.text,
    ];
    expect(await texts(), ['newer']);
    await svc.fullResync();
    await svc.vault.whenIdle();
    expect(await texts(), ['newer']);
  });

  test('full resync is idempotent: no duplicates, nothing deleted comes '
      'back', () async {
    bridge(lxmf: [convMap(peerKeep)]);
    await connect();
    await deliver(devY, 1, 'messages', {
      'records': [rec('y1', t0), rec('y2', t0 + 1000)],
    });
    Future<List<int>> snapshot() async => [
      await count('messages'),
      await count('chats'),
      await count('vault_messages'),
      await count('vault_chats'),
    ];
    final before = await snapshot();
    expect(before[0], 2); // the two bridge messages of peerKeep
    expect(before[2], 2);
    syncCursors.clear();
    await svc.fullResync();
    await svc.fullResync();
    expect(syncCursors.first, 0);
    expect(await snapshot(), before);
  });
}
