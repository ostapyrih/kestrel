import 'dart:typed_data';

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

final me = '0a' * 16; // this device
final devY = 'bb' * 16; // the owner of a read-only chat
final devZ = 'dd' * 16; // a third device
final peer = '11' * 16;
final peer2 = '22' * 16;

const t0 = 1700000000000; // ms

Future<int> count(AppDatabase a, String table, [String? where]) async =>
    Sqflite.firstIntValue(
      await a.db.rawQuery(
        'SELECT COUNT(*) FROM $table${where == null ? '' : ' WHERE $where'}',
      ),
    )!;

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase adb;
  late Repo repo;

  setUp(() async {
    adb = await AppDatabase.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    repo = Repo(adb);
  });

  tearDown(() => adb.close());

  Future<int> addIn(
    String identity,
    String peerHash,
    String hash,
    int ts, {
    String text = 't',
  }) async {
    final chat = await repo.findOrCreateChat(identity, peerHash, title: 'P');
    return repo.insertIncoming(
      identity: identity,
      chatId: chat,
      lxmfHash: hash,
      text: text,
      ts: DateTime.fromMillisecondsSinceEpoch(ts),
      route: 'direct',
      transport: 'tcp',
      signatureValid: true,
    );
  }

  Future<({int messageId, int outboxId})> addOut(
    String identity,
    String peerHash,
    String text,
  ) async {
    final chat = await repo.findOrCreateChat(identity, peerHash, title: 'P');
    return repo.insertOutgoing(
      identity: identity,
      chatId: chat,
      destinationHash: peerHash,
      text: text,
      route: identity == 'A' ? 'via_bridge' : 'opportunistic',
      transport: 'none',
    );
  }

  group('Repo.deleteChats', () {
    test('hard-deletes one chat with log and outbox, never another '
        'account or chat', () async {
      await addIn('B', peer, 'b1', t0);
      final out = await addOut('B', peer, 'unsent');
      await repo.addLog(out.messageId, 'extra');
      // the same peer under account A, and another B chat
      await addIn('A', peer, 'a1', t0);
      await addOut('A', peer, 'a unsent');
      await addIn('B', peer2, 'b2', t0);
      final chatB = (await repo.chats(accountIdentity: 'B'))
          .firstWhere((c) => c.peerHash == peer);
      expect(await repo.unsentCount([chatB.id]), 1);

      final r = await repo.deleteChats([chatB.id]);
      expect(r.single.identity, 'B');
      expect(r.single.messages, 2);
      expect(r.single.unsent, 1);
      expect(r.single.peerHash, peer);

      // real DELETE, not a flag: the rows are gone from the tables
      expect(await count(adb, 'chats', 'id = ${chatB.id}'), 0);
      expect(await count(adb, 'messages', 'chat_id = ${chatB.id}'), 0);
      expect(await count(adb, 'outbox', 'chat_id = ${chatB.id}'), 0);
      expect(
        await count(adb, 'delivery_log', 'message_id = ${out.messageId}'),
        0,
      );
      // everything else is untouched
      expect(await count(adb, 'chats'), 2);
      expect((await repo.chats(accountIdentity: 'A')).single.peerHash, peer);
      expect(await count(adb, 'messages', "sender_identity = 'A'"), 2);
      expect(await count(adb, 'outbox'), 1); // the A outbox row
      expect((await repo.chats(accountIdentity: 'B')).single.peerHash, peer2);
      expect(await count(adb, 'messages', "sender_identity = 'B'"), 1);
    });

    test('an A chat is deleted by its own account id only', () async {
      await addIn('A', peer, 'a1', t0);
      await addIn('B', peer, 'b1', t0);
      final a = (await repo.chats(accountIdentity: 'A')).single;
      await repo.deleteChats([a.id]);
      expect(await repo.chats(accountIdentity: 'A'), isEmpty);
      expect((await repo.chats(accountIdentity: 'B')).single.peerHash, peer);
      expect(await count(adb, 'messages'), 1);
    });

    test('a read-only (negative) id is ignored', () async {
      await addIn('B', peer, 'b1', t0);
      expect(await repo.deleteChats([-1, 999]), isEmpty);
      expect(await count(adb, 'messages'), 1);
    });

    test('a vault upload mark of a deleted message does not linger and a '
        'delete_chat is queued only for uploaded B chats', () async {
      final m1 = await addIn('B', peer, 'b1', t0);
      await addIn('B', peer2, 'b2', t0);
      await adb.db.insert('vault_upload', {
        'message_id': m1,
        'gen': 0,
        'status': 'received',
        'lxmf_hash': 'b1',
      });
      final chats = await repo.chats(accountIdentity: 'B');
      await repo.deleteChats([for (final c in chats) c.id]);
      expect(await count(adb, 'vault_upload'), 0);
      final q = await adb.db.query('vault_delete_out');
      expect(q, hasLength(1)); // peer2 was never uploaded: no blob needed
      expect(q.single['peer_hash'], peer);
      expect(q.single['owner_device'], isNull);
      expect(q.single['before_ts'], t0);
    });
  });

  group('Repo.applyChatDeleted (account A, from the bridge)', () {
    test('removes synced messages up to before_ts, keeps newer and unsent, '
        'never touches B', () async {
      await adb.db.update('chats', {'bridge_last_id': 1});
      final chatA = await repo.findOrCreateChat('A', peer, title: 'P');
      for (final (i, ts) in [t0, t0 + 1000, t0 + 5000].indexed) {
        await adb.db.insert('messages', {
          'account_id': await repo.accountId('A'),
          'chat_id': chatA,
          'direction': 'in',
          'lxmf_hash': 'a$i',
          'text': 't$i',
          'ts': ts,
          'sender_identity': 'A',
          'transport': 'tcp',
          'status': 'received',
          'bridge_id': i + 1,
        });
      }
      final unsent = await addOut('A', peer, 'not sent yet'); // ts = now
      await addIn('B', peer, 'b1', t0);
      expect(await repo.applyChatDeleted(peer, (t0 + 1000) / 1000), isTrue);
      final left = (await repo.messages(chatA)).map((m) => m.text).toList();
      expect(left, containsAll(['t2', 'not sent yet']));
      expect(left, hasLength(2));
      expect(await count(adb, 'outbox', 'message_id = ${unsent.messageId}'), 1);
      expect(await count(adb, 'messages', "sender_identity = 'B'"), 1);
      // everything up to a later time: the synced one goes, the chat stays
      // because of the unsent message
      await repo.applyChatDeleted(peer, (t0 + 9000) / 1000);
      expect((await repo.messages(chatA)).map((m) => m.text), ['not sent yet']);
      expect(await repo.chat(chatA), isNotNull);
    });

    test(
      'the chat disappears once nothing is left; unknown peer is a no-op',
      () async {
        await adb.db.insert('chats', {
          'account_id': await repo.accountId('A'),
          'kind': 'lxmf',
          'peer_hash': peer,
        });
        expect(await repo.applyChatDeleted(peer2, 1), isFalse);
        await repo.applyChatDeleted(peer, 1e12);
        expect(await repo.chats(accountIdentity: 'A'), isEmpty);
      },
    );
  });

  group('Repo.removeVaultHistory', () {
    Future<void> remoteMsg(String dev, String hash, int ts) async {
      final c =
          (await adb.db.query(
            'vault_chats',
            where: 'device_id = ? AND peer_hash = ?',
            whereArgs: [dev, peer],
          )).firstOrNull?['id'] ??
          await adb.db.insert('vault_chats', {
            'device_id': dev,
            'peer_hash': peer,
            'last_ts': ts,
          });
      await adb.db.insert('vault_messages', {
        'chat_id': c,
        'device_id': dev,
        'lxmf_hash': hash,
        'direction': 'in',
        'text': 'x',
        'ts': ts,
        'rts': 1.0,
        'status': 'received',
      });
    }

    test(
      'only the named device, up to before_ts, and it is remembered',
      () async {
        await remoteMsg(devY, 'y1', t0);
        await remoteMsg(devY, 'y2', t0 + 5000);
        await remoteMsg(devZ, 'z1', t0);
        await repo.removeVaultHistory(devY, peer, beforeTsMs: t0 + 1000);
        expect(await count(adb, 'vault_messages', "device_id = '$devY'"), 1);
        expect(await count(adb, 'vault_messages', "device_id = '$devZ'"), 1);
        expect(await count(adb, 'vault_chats'), 2);
        final t = await adb.db.query('vault_tombstones');
        expect(t.single['device_id'], devY);
        expect(t.single['before_ts'], t0 + 1000);
        expect(await count(adb, 'vault_delete_out'), 0);
      },
    );

    test('uploadDelete queues a blob naming the owner; the tombstone '
        'survives turning the bridge off', () async {
      await remoteMsg(devY, 'y1', t0);
      await repo.removeVaultHistory(devY, peer, uploadDelete: true);
      expect(await count(adb, 'vault_chats'), 0);
      final q = (await adb.db.query('vault_delete_out')).single;
      expect(q['owner_device'], devY);
      expect(q['before_ts'], t0);
      await repo.purgeBridgeAccountData();
      expect(await count(adb, 'vault_tombstones'), 1);
      expect(await count(adb, 'vault_delete_out'), 1);
    });
  });

  // ------------------------------------------------------------------- vault
  group('vault: delete_chat blobs', () {
    late FakeBridgeApi api;
    late BridgeService svc;
    late Identity mine;
    late Identity theirs;
    late Identity third;
    late VaultServer server;
    late MemorySecretStore secrets;
    final cancelled = <String>[];

    Future<void> connect() async {
      api.connect(helloFor(me, stateId: 'st1'));
      await svc.flushEvents();
      await svc.vault.whenIdle();
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
    }

    Map<String, Object?> rec(String hash, int tsMs, {String text = 'old'}) => {
      'hash': hash,
      'peer': peer,
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

    Future<List<Map<String, Object?>>> ownBlobs(String kind) async {
      final out = <Map<String, Object?>>[];
      for (final p in server.putLog) {
        final plain = await VaultCrypto.decryptBlob(
          ciphertext: p['ciphertext']! as Uint8List,
          chain: svc.vault.keys.chain,
          blobId: p['blob_id']! as String,
          deviceId: me,
          seq: p['seq']! as int,
          keyEpoch: 1,
        );
        if (plain.kind == kind) {
          out.add({'seq': p['seq'], 'data': plain.data});
        }
      }
      return out;
    }

    setUp(() async {
      api = FakeBridgeApi(vaultStubs: false);
      mine = await Identity.generate();
      theirs = await Identity.generate();
      third = await Identity.generate();
      secrets = MemorySecretStore();
      cancelled.clear();
      server = VaultServer(api, {
        me: (devMap(me, mine, name: 'This'), mine),
        devY: (devMap(devY, theirs, name: 'Phone'), theirs),
        devZ: (devMap(devZ, third, name: 'Laptop'), third),
      })..install();
      api.handlers['/sync_chats'] = (a) => {
        'state_id': 'st1',
        'cursor': 0,
        'reset': false,
        'more': false,
        'lxmf': <Object?>[],
        'rrc': <Object?>[],
      };
      api.handlers['/list_rooms'] = (a) => {'hubs': []};
      svc = BridgeService(
        repo: repo,
        ownDeviceId: () => me,
        identity: () => mine,
        apiFactory: (_, _) => api,
        secrets: secrets,
        sendAsB: (c, t) async => 0,
      );
      svc.vault.cancelOutbound = (h) async => cancelled.addAll(h);
      await svc.configure('bridge public key: ${'cd' * 64}');
    });

    tearDown(() => svc.stop());

    test('deleting an uploaded own B chat uploads a tombstone AFTER the '
        'messages and never uploads the messages again', () async {
      await addIn('B', peer, 'b1', t0);
      await addIn('B', peer, 'b2', t0 + 2000);
      await connect();
      expect(await ownBlobs('messages'), hasLength(1));
      final chat = (await repo.chats(accountIdentity: 'B')).single;
      await repo.deleteChats([chat.id]);
      await svc.vault.onKeysMayHaveChanged();
      await svc.vault.whenIdle();
      final del = await ownBlobs('delete_chat');
      expect(del, hasLength(1));
      expect(del.single['seq'], 2);
      final d = del.single['data']! as Map;
      expect(d['peer'], peer);
      expect(d.containsKey('owner_device'), isFalse); // own chat
      expect(d['before_ts'], (t0 + 2000) / 1000);
      expect(await ownBlobs('messages'), hasLength(1)); // nothing re-uploaded
      expect(await count(adb, 'vault_delete_out'), 0);
      // a later passes upload nothing; a new message starts a fresh chat
      await svc.vault.onKeysMayHaveChanged();
      expect(server.putLog, hasLength(2));
      await addIn('B', peer, 'b3', t0 + 9000, text: 'fresh');
      await svc.vault.onKeysMayHaveChanged();
      final msgs = await ownBlobs('messages');
      expect(msgs, hasLength(2));
      final recs = ((msgs.last['data']! as Map)['records'] as List).cast<Map>();
      expect(recs.map((r) => r['text']), ['fresh']);
    });

    test('a blob built before the deletion is dropped, not uploaded', () async {
      await addIn('B', peer, 'b1', t0);
      await connect();
      // an unsent-to-the-bridge blob exists (simulate: build one, then delete)
      server.putFailuresLeft = 0;
      await addIn('B', peer, 'b2', t0 + 1000);
      final id = (await repo.chats(accountIdentity: 'B')).single.id;
      final b2 = (await repo.messages(id)).last.id;
      await adb.db.insert('vault_pending', {
        'id': 1,
        'blob_id': 'ff' * 16,
        'seq': 2,
        'key_epoch': 1,
        'ciphertext': Uint8List(8),
        'marks': '[[$b2,"received",null,"b2"]]',
      });
      await repo.deleteChats([id]);
      expect(await count(adb, 'vault_pending'), 0);
    });

    test(
      'a delete_chat from another device removes its read-only copy up to '
      'before_ts; newer survives; a re-download does not resurrect',
      () async {
        await connect();
        await deliver(devY, 1, 'messages', {
          'records': [rec('y1', t0), rec('y2', t0 + 1000)],
        });
        expect(await repo.remoteChats(), hasLength(1));
        await deliver(devY, 2, 'delete_chat', {
          'peer': peer,
          'before_ts': (t0 + 1000) / 1000,
        });
        expect(await repo.remoteChats(), isEmpty);
        await deliver(devY, 3, 'messages', {
          'records': [rec('y3', t0 + 9000, text: 'newer')],
        });
        final chats = await repo.remoteChats();
        expect(chats.single.remoteDeviceId, devY);
        expect((await repo.messages(chats.single.id)).map((m) => m.text), [
          'newer',
        ]);
        // read everything again (cursor reset, bridge toggled): the deleted
        // messages are in the old blobs but stay away
        await svc.vault.store.rewind();
        await svc.vault.onKeysMayHaveChanged();
        expect(
          (await repo.messages((await repo.remoteChats()).single.id))
              .map((m) => m.text),
          ['newer'],
        );
        // a late stale record (older than the tombstone) is skipped as well
        await deliver(devY, 4, 'messages', {
          'records': [rec('y1', t0, text: 'late status update')],
        });
        expect(
          (await repo.messages((await repo.remoteChats()).single.id)),
          hasLength(1),
        );
      },
    );

    test('X deletes the read-only chat of Y: gone here, queued for everyone '
        'with owner_device, disabled without the vault', () async {
      expect(svc.vault.canDeleteRemote, isFalse); // not connected, no key
      await connect();
      expect(svc.vault.canDeleteRemote, isTrue);
      await deliver(devY, 1, 'messages', {
        'records': [rec('y1', t0), rec('y2', t0 + 3000)],
      });
      final c = (await repo.remoteChats()).single;
      await repo.removeVaultHistory(
        c.remoteDeviceId!,
        c.peerHash!,
        uploadDelete: true,
      );
      expect(await repo.remoteChats(), isEmpty);
      await svc.vault.onKeysMayHaveChanged();
      await svc.vault.whenIdle();
      final del = await ownBlobs('delete_chat');
      expect(del, hasLength(1));
      final d = del.single['data']! as Map;
      expect((d['peer'], d['owner_device']), (peer, devY));
      expect(d['before_ts'], (t0 + 3000) / 1000); // newest message X knew
      // ... and my own B chat with that peer is not touched
      expect(await repo.chats(accountIdentity: 'B'), isEmpty);
    });

    test(
      'Y applies a delete_chat that names it: own B chat gone up to '
      'before_ts, unsent cancelled, newer survives, never re-uploaded',
      () async {
        await addIn('B', peer, 'b1', t0);
        await addIn('B', peer, 'b2', t0 + 2000);
        final out = await addOut('B', peer, 'queued reply');
        await repo.updateMessage(out.messageId, lxmfHash: 'qq' * 16);
        await adb.db.update(
          'messages',
          {'ts': t0 + 3000},
          where: 'id = ?',
          whereArgs: [out.messageId],
        );
        await addIn('B', peer, 'b4', t0 + 90000, text: 'newer');
        await connect();
        expect(await ownBlobs('messages'), hasLength(1));
        // another device (Z) deletes the chat of this device everywhere
        await deliver(devZ, 1, 'delete_chat', {
          'peer': peer,
          'owner_device': me,
          'before_ts': (t0 + 5000) / 1000,
        });
        expect(cancelled, ['qq' * 16]);
        final chat = (await repo.chats(accountIdentity: 'B')).single;
        expect((await repo.messages(chat.id)).map((m) => m.text), ['newer']);
        expect(await count(adb, 'outbox'), 0);
        expect(
          await count(adb, 'delivery_log', 'message_id = ${out.messageId}'),
          0,
        );
        final t = await adb.db.query('vault_tombstones');
        expect((t.single['device_id'], t.single['before_ts']), (me, t0 + 5000));
        // the deletion does not echo back as a delete blob of ours
        await svc.vault.onKeysMayHaveChanged();
        expect(await ownBlobs('delete_chat'), isEmpty);
        // re-download: applied again, idempotent, newer message still there
        await svc.vault.store.rewind();
        await svc.vault.onKeysMayHaveChanged();
        expect((await repo.messages(chat.id)).map((m) => m.text), ['newer']);
      },
    );

    test('a third device drops its copy of the chat that Y owns', () async {
      await connect();
      await deliver(devY, 1, 'messages', {
        'records': [rec('y1', t0)],
      });
      expect(await repo.remoteChats(), hasLength(1));
      // X (devZ) deletes Y's chat: owner_device names Y, uploader is Z
      await deliver(devZ, 1, 'delete_chat', {
        'peer': peer,
        'owner_device': devY,
        'before_ts': (t0 + 1000) / 1000,
      });
      expect(await repo.remoteChats(), isEmpty);
      expect(await count(adb, 'vault_tombstones', "device_id = '$devY'"), 1);
    });

    test('a tombstone for an unknown owner still removes local copies and '
        'garbage is ignored', () async {
      await connect();
      final ghost = 'ee' * 16;
      await deliver(ghost, 1, 'messages', {
        'records': [rec('g1', t0)],
      });
      expect(await repo.remoteChats(), hasLength(1));
      await deliver(devZ, 1, 'delete_chat', {
        'peer': peer,
        'owner_device': ghost,
        'before_ts': (t0 + 1) / 1000,
      });
      expect(await repo.remoteChats(), isEmpty);
      await deliver(devZ, 2, 'delete_chat', {'peer': 5, 'before_ts': 'x'});
      await deliver(devZ, 3, 'delete_chat', {'before_ts': 1.0});
      expect(await count(adb, 'vault_tombstones'), 1);
    });
  });

  // ---------------------------------------------------------------- account A
  group('A chat via the bridge', () {
    late FakeBridgeApi api;
    late BridgeService svc;
    late Identity identity;

    HelloResult hello({bool canDelete = true}) =>
        helloFor(me, capabilities: ['lxmf', if (canDelete) 'delete_chat']);

    Future<void> up({bool canDelete = true}) async {
      api.connect(hello(canDelete: canDelete));
      await svc.flushEvents();
    }

    void handlers() {
      api.handlers['/sync_chats'] = (a) => {
        'state_id': 'state1',
        'cursor': 1,
        'reset': false,
        'more': false,
        'lxmf': [convMap(peer)],
        'rrc': <Object?>[],
      };
      api.handlers['/get_messages'] = (a) => {
        'peer': peer,
        'has_more': false,
        'gap': false,
        'messages': [msgMap(1, 'a1' * 16, text: 'hello', ts: 1700000000)],
      };
      api.handlers['/devices/list'] = (a) => {
        'devices': [deviceMap(me, name: 'This', bootstrap: true)],
        'key_epoch': 1,
      };
      api.handlers['/list_rooms'] = (a) => {'hubs': []};
    }

    setUp(() async {
      api = FakeBridgeApi();
      identity = await Identity.generate();
      svc = BridgeService(
        repo: repo,
        ownDeviceId: () => me,
        identity: () => identity,
        apiFactory: (_, _) => api,
        sendAsB: (c, t) async => 0,
      );
      handlers();
      await svc.configure('bridge public key: ${'cd' * 64}');
    });

    tearDown(() => svc.stop());

    test('delete for all: /delete_chat, then the local chat, messages and '
        'unsent ones are gone', () async {
      api.handlers['/delete_chat'] = (a) => {
        'peer': a['peer'],
        'before_ts': 1700000100.0,
        'cursor': 2,
      };
      await up();
      final chat = (await svc.store.chatIdForPeer(peer))!;
      await addOut('A', peer, 'unsent');
      expect(svc.canDeleteChat, isTrue);
      await svc.deleteAChat(chat);
      expect(api.callsTo('/delete_chat').single, {'peer': peer});
      expect(await repo.chats(accountIdentity: 'A'), isEmpty);
      expect(await count(adb, 'messages'), 0);
      expect(await count(adb, 'outbox'), 0);
      // the sync cursor did not move back: a resync brings nothing back
      api.handlers['/sync_chats'] = (a) => {
        'state_id': 'state1',
        'cursor': 2,
        'reset': true,
        'more': false,
        'lxmf': <Object?>[],
        'rrc': <Object?>[],
        'deleted': [
          {'peer': peer, 'before_ts': 1700000100.0},
        ],
      };
      await svc.resync();
      expect(await repo.chats(accountIdentity: 'A'), isEmpty);
    });

    test('not_found counts as deleted; other errors change nothing', () async {
      await up();
      final chat = (await svc.store.chatIdForPeer(peer))!;
      api.handlers['/delete_chat'] = (a) =>
          throw BridgeError('upstream_error', 'boom');
      await expectLater(svc.deleteAChat(chat), throwsA(isA<BridgeError>()));
      expect(await repo.chat(chat), isNotNull);
      expect(await count(adb, 'messages'), 1);
      api.handlers['/delete_chat'] = (a) =>
          throw BridgeError('not_found', 'gone');
      await svc.deleteAChat(chat);
      expect(await repo.chat(chat), isNull);
    });

    test('an old bridge cannot delete; nothing is sent or removed', () async {
      await up(canDelete: false);
      final chat = (await svc.store.chatIdForPeer(peer))!;
      expect(svc.canDeleteChat, isFalse);
      await expectLater(svc.deleteAChat(chat), throwsA(isA<BridgeError>()));
      expect(api.callsTo('/delete_chat'), isEmpty);
      expect(await repo.chat(chat), isNotNull);
    });

    test('chat_deleted push from another device removes the local copy; '
        'newer messages survive', () async {
      await up();
      final chat = (await svc.store.chatIdForPeer(peer))!;
      await adb.db.insert('messages', {
        'account_id': await repo.accountId('A'),
        'chat_id': chat,
        'direction': 'in',
        'lxmf_hash': 'new',
        'text': 'newer',
        'ts': 1700000500000,
        'sender_identity': 'A',
        'transport': 'tcp',
        'status': 'received',
        'bridge_id': 9,
      });
      api.push('chat_deleted', {
        'peer': peer,
        'before_ts': 1700000100.0,
        'cursor': 3,
        'by_device': 'dd' * 16,
      });
      await svc.flushEvents();
      expect((await repo.messages(chat)).map((m) => m.text), ['newer']);
      api.push('chat_deleted', {
        'peer': peer,
        'before_ts': 1700009999.0,
        'cursor': 4,
        'by_device': null,
      }, id: 'ev2');
      await svc.flushEvents();
      expect(await repo.chat(chat), isNull);
    });

    test('/sync_chats deleted[] removes the chat on a device that was '
        'offline during the deletion', () async {
      await up();
      final chat = (await svc.store.chatIdForPeer(peer))!;
      expect(chat, isNonZero);
      api.handlers['/sync_chats'] = (a) => {
        'state_id': 'state1',
        'cursor': 5,
        'reset': false,
        'more': false,
        'lxmf': <Object?>[],
        'rrc': <Object?>[],
        'deleted': [
          {'peer': peer, 'before_ts': 1700000100.0},
        ],
      };
      await svc.resync();
      expect(await repo.chat(chat), isNull);
      expect(await count(adb, 'messages'), 0);
    });
  });
}
