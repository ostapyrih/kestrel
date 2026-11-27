import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<AppDatabase> _open([String path = inMemoryDatabasePath]) =>
    AppDatabase.open(path, factory: databaseFactoryFfi);

Future<int> _count(AppDatabase a, String table) async =>
    Sqflite.firstIntValue(await a.db.rawQuery('SELECT COUNT(*) FROM $table'))!;

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'fresh database has the PLAN schema, both accounts and bridge off',
    () async {
      final a = await _open();
      final tables = (await a.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((r) => r['name']! as String).toSet();
      expect(
        tables,
        containsAll([
          'accounts',
          'chats',
          'messages',
          'outbox',
          'delivery_log',
          'settings',
          'peers',
        ]),
      );
      final acc = await a.db.query('accounts', orderBy: 'identity');
      expect(acc.map((r) => (r['identity'], r['kind'])), [
        ('A', 'remote'),
        ('B', 'local'),
      ]);
      expect(await Repo(a).bridgeEnabled(), isFalse);
      expect(
        Sqflite.firstIntValue(await a.db.rawQuery('PRAGMA user_version')),
        latestSchemaVersion,
      );
      // message columns from PLAN section 4
      final cols = (await a.db.rawQuery('PRAGMA table_info(messages)'))
          .map((r) => r['name']! as String);
      expect(
        cols,
        containsAll([
          'account_id',
          'chat_id',
          'direction',
          'lxmf_hash',
          'text',
          'ts',
          'sender_identity',
          'route',
          'transport',
          'status',
          'error',
        ]),
      );
      await a.close();
    },
  );

  test('migrations: an old v1 database upgrades without losing rows', () async {
    final dir = await Directory.systemTemp.createTemp('kestrel-db');
    final path = '${dir.path}/old.db';
    // Build a v1 database by hand.
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (d, v) => migrate(d, 0, 1),
      ),
    );
    await old.insert('accounts', {
      'identity': 'B',
      'kind': 'local',
      'label': 'B',
    });
    await old.insert('chats', {
      'account_id': 1,
      'kind': 'lxmf',
      'peer_hash': 'ab' * 16,
      'title': 'Old chat',
    });
    await old.insert('messages', {
      'account_id': 1,
      'chat_id': 1,
      'direction': 'in',
      'text': 'kept',
      'ts': 1,
      'sender_identity': 'B',
      'status': 'received',
    });
    await old.close();

    final a = await _open(path);
    expect(
      Sqflite.firstIntValue(await a.db.rawQuery('PRAGMA user_version')),
      latestSchemaVersion,
    );
    expect(await _count(a, 'peers'), 0); // table from migration 2 exists
    expect(await _count(a, 'bridge_devices'), 0); // migration 3 tables
    expect(await _count(a, 'rrc_rooms'), 0);
    expect((await Repo(a).chat(1))!.bridgeLastId, isNull);
    expect((await Repo(a).messages(1)).single.text, 'kept');
    expect((await Repo(a).chat(1))!.title, 'Old chat');
    expect(await _count(a, 'accounts'), 2); // A placeholder added on open
    await a.close();
    await dir.delete(recursive: true);
  });

  test(
    'toggling bridge_enabled never removes or changes chats/messages',
    () async {
      final a = await _open();
      final repo = Repo(a);
      final chatB = await repo.findOrCreateChat('B', 'aa' * 16, title: 'Alice');
      // An "A" (bridge) chat exists in the same database.
      final chatA = await repo.findOrCreateChat(
        'A',
        'bb' * 16,
        title: 'Via bridge',
      );
      await repo.insertIncoming(
        identity: 'B',
        chatId: chatB,
        lxmfHash: 'h1',
        text: 'hello',
        ts: DateTime.now(),
        route: 'opportunistic',
        transport: 'tcp',
        signatureValid: true,
      );
      await repo.insertOutgoing(
        identity: 'B',
        chatId: chatB,
        destinationHash: 'aa' * 16,
        text: 'reply',
        route: 'opportunistic',
        transport: 'none',
      );
      await repo.insertOutgoing(
        identity: 'A',
        chatId: chatA,
        destinationHash: 'bb' * 16,
        text: 'via bridge',
        route: 'via_bridge',
        transport: 'none',
      );

      Future<Map<String, Object?>> snapshot() async => {
        'chats': await a.db.query('chats', orderBy: 'id'),
        'messages': await a.db.query('messages', orderBy: 'id'),
        'outbox': await a.db.query('outbox', orderBy: 'id'),
        'log': await a.db.query('delivery_log', orderBy: 'id'),
      };

      final before = await snapshot();
      for (var i = 0; i < 4; i++) {
        await repo.setBridgeEnabled(i.isEven);
        expect(await repo.bridgeEnabled(), i.isEven);
      }
      await repo.setBridgeEnabled(false);
      expect(await snapshot(), before);
      expect(await _count(a, 'chats'), 2);
      expect(await _count(a, 'messages'), 3);
      // Both identities stay visible in the chat list.
      expect((await repo.chats()).length, 2);
      expect((await repo.chats(accountIdentity: 'B')).single.title, 'Alice');
      expect(
        (await repo.chats(accountIdentity: 'A')).single.title,
        'Via bridge',
      );
      await a.close();
    },
  );

  test('the only code that deletes chats or messages is '
      'Repo.purgeBridgeAccountData (account A), the vault cache reset, '
      'Repo._deleteChatRows (scoped by account) and removeVaultHistory '
      '(scoped by device)', () {
    final re = RegExp(
      r'''(DELETE\s+FROM\s+(chats|messages|outbox|delivery_log|vault_chats|vault_messages)\b|\.delete\(\s*['"](chats|messages|outbox|delivery_log|vault_chats|vault_messages)['"]|DROP\s+TABLE)''',
      caseSensitive: false,
    );
    final offenders = <String>[];
    String? purge;
    String? deleteRows;
    String? vaultRemoval;
    for (final f
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      var src = f.readAsStringSync().replaceAll('\r\n', '\n');
      if (f.path.replaceAll('\\', '/').endsWith('storage/repo.dart')) {
        final start = src.indexOf('Future<void> purgeBridgeAccountData()');
        expect(start, greaterThan(0), reason: 'the purge method exists');
        final end = src.indexOf('\n  }\n', start);
        purge = src.substring(start, end);
        src = src.substring(0, start) + src.substring(end);
        // the second allowed place: it only drops vault caches (the
        // downloaded histories of other devices), never own B data
        final rs = src.indexOf('Future<void> resetVaultForNewBridge()');
        expect(rs, greaterThan(0), reason: 'the vault reset method exists');
        final re2 = src.indexOf('\n  }\n', rs);
        final reset = src.substring(rs, re2);
        expect(
          RegExp(r'DELETE FROM (chats|messages|outbox|delivery_log)\b')
              .hasMatch(reset),
          isFalse,
          reason: 'the vault reset must not touch chats or messages',
        );
        src = src.substring(0, rs) + src.substring(re2);
        // chat deletion: exactly these two methods may delete chat rows
        String take(String signature) {
          final i = src.indexOf(signature);
          expect(i, greaterThan(0), reason: '$signature exists');
          final j = src.indexOf('\n  }\n', i);
          final body = src.substring(i, j);
          src = src.substring(0, i) + src.substring(j);
          return body;
        }

        deleteRows = take('Future<_Deleted> _deleteChatRows(');
        vaultRemoval = take('Future<void> removeVaultHistory(');
      }
      if (re.hasMatch(src)) offenders.add(f.path);
    }
    expect(offenders, isEmpty);
    // every statement of the purge on account tables is bound to account A
    expect(purge, isNotNull);
    final stmts = RegExp(r'DELETE FROM (chats|messages|outbox|delivery_log)')
        .allMatches(purge!)
        .toList();
    expect(stmts, hasLength(4));
    for (final m in stmts) {
      final tail = purge.substring(
        m.start,
        (m.start + 160).clamp(0, purge.length),
      );
      expect(
        tail,
        contains('account_id = ?'),
        reason: 'DELETE FROM ${m.group(1)} must be limited to account A',
      );
    }
    // the chat deletion: four statements, each scoped by the account of the
    // chat being deleted (never another account's rows) ...
    expect(deleteRows, isNotNull);
    final dels = RegExp(
      r'DELETE FROM (chats|messages|outbox|delivery_log)\b',
    ).allMatches(deleteRows!).toList();
    expect(dels.map((m) => m.group(1)).toSet(), {
      'chats',
      'messages',
      'outbox',
      'delivery_log',
    });
    expect(dels, hasLength(4));
    for (final m in dels) {
      final tail = deleteRows.substring(
        m.start,
        (m.start + 200).clamp(0, deleteRows.length),
      );
      expect(
        tail,
        contains('account_id = ?'),
        reason: 'DELETE FROM ${m.group(1)} must be scoped by account_id',
      );
    }
    // ... and the other-device history removal only touches one device's rows
    expect(vaultRemoval, isNotNull);
    final vdels = RegExp(
      r'DELETE FROM (vault_chats|vault_messages)',
    ).allMatches(vaultRemoval!).toList();
    expect(vdels, hasLength(2));
    for (final m in vdels) {
      expect(
        vaultRemoval.substring(m.start, m.start + 120),
        contains('device_id = ?'),
      );
    }
  });

  test('purgeBridgeAccountData removes account A only and keeps B and the '
      'pairing', () async {
    final a = await _open();
    final repo = Repo(a);
    final chatB = await repo.findOrCreateChat('B', 'aa' * 16, title: 'Alice');
    final chatA = await repo.findOrCreateChat('A', 'bb' * 16, title: 'Via');
    final roomChat = await repo.findOrCreateChat('A', 'cc' * 16, title: 'Two');
    await repo.insertIncoming(
      identity: 'B',
      chatId: chatB,
      lxmfHash: 'h-b',
      text: 'hello b',
      ts: DateTime.now(),
      route: 'direct',
      transport: 'tcp',
      signatureValid: true,
    );
    await repo.insertIncoming(
      identity: 'A',
      chatId: chatA,
      lxmfHash: 'h-a',
      text: 'hello a',
      ts: DateTime.now(),
      route: 'via_bridge',
      transport: 'tcp',
      signatureValid: true,
    );
    final outB = await repo.insertOutgoing(
      identity: 'B',
      chatId: chatB,
      destinationHash: 'aa' * 16,
      text: 'b out',
      route: 'opportunistic',
      transport: 'none',
    );
    final outA = await repo.insertOutgoing(
      identity: 'A',
      chatId: roomChat,
      destinationHash: 'cc' * 16,
      text: 'a out',
      route: 'via_bridge',
      transport: 'none',
    );
    await repo.addLog(outB.messageId, 'queued');
    await repo.addLog(outA.messageId, 'queued');
    await a.db.insert('rrc_rooms', {'hub': 'h', 'room': 'r'});
    await a.db.insert('rrc_messages', {
      'hub': 'h',
      'room': 'r',
      'seq': 1,
      'text': 't',
      'ts': 1,
    });
    await a.db.insert('bridge_devices', {'device_id': 'dd', 'name': 'x'});
    // vault: a downloaded remote history, and this device's upload progress
    final vc = await a.db.insert('vault_chats', {
      'device_id': 'dd',
      'peer_hash': 'ee' * 16,
      'peer_name': 'Remote peer',
      'last_ts': 5,
    });
    await a.db.insert('vault_messages', {
      'chat_id': vc,
      'device_id': 'dd',
      'lxmf_hash': 'h-remote',
      'direction': 'in',
      'text': 'remote text',
      'ts': 5,
      'rts': 5.0,
      'status': 'received',
    });
    await a.db.insert('vault_seen', {'device_id': 'dd', 'last_seq': 4});
    await a.db.insert('vault_upload', {
      'message_id': outB.messageId,
      'status': 'sent',
    });
    await repo.setSetting(SettingKeys.vaultCursor, '9');
    await repo.setSetting(SettingKeys.vaultLastSeq, '12');
    await repo.setSetting(SettingKeys.bridgePubkey, 'ab' * 64);
    await repo.setSetting(SettingKeys.bridgeCursor, '42');
    await repo.setSetting(SettingKeys.bridgeStateId, 'st');
    await repo.setSetting(SettingKeys.deviceName, 'Mine');
    await repo.setBridgeEnabled(true);

    Future<int> logOf(String id) async => Sqflite.firstIntValue(
      await a.db.rawQuery(
        'SELECT COUNT(*) FROM delivery_log WHERE message_id IN '
        '(SELECT m.id FROM messages m JOIN accounts x ON x.id = m.account_id '
        'WHERE x.identity = ?)',
        [id],
      ),
    )!;
    final logB = await logOf('B');
    expect(logB, greaterThan(0));
    expect(await logOf('A'), greaterThan(0));

    await repo.purgeBridgeAccountData();

    // account B is intact
    expect((await repo.chats()).map((c) => c.title), ['Alice']);
    expect((await repo.messages(chatB)).map((m) => m.text), [
      'hello b',
      'b out',
    ]);
    expect(await _count(a, 'outbox'), 1);
    expect(await _count(a, 'delivery_log'), logB);
    expect(await logOf('B'), logB);
    // everything of account A is gone
    expect(await _count(a, 'messages'), 2);
    expect(await _count(a, 'rrc_rooms'), 0);
    expect(await _count(a, 'rrc_messages'), 0);
    expect(await _count(a, 'bridge_devices'), 0);
    // downloaded histories of other devices are gone, the vault cursor reset
    expect(await _count(a, 'vault_chats'), 0);
    expect(await _count(a, 'vault_messages'), 0);
    expect(await _count(a, 'vault_seen'), 0);
    expect(await repo.getSetting(SettingKeys.vaultCursor), '0');
    expect(await repo.remoteChats(), isEmpty);
    // this device's upload progress survives, so re-enabling continues
    expect(await _count(a, 'vault_upload'), 1);
    expect(await repo.getSetting(SettingKeys.vaultLastSeq), '12');
    expect(await repo.getSetting(SettingKeys.bridgeCursor), '0');
    expect(await repo.getSetting(SettingKeys.bridgeStateId), '');
    // the pairing and the user's settings stay
    expect(await repo.getSetting(SettingKeys.bridgePubkey), 'ab' * 64);
    expect(await repo.getSetting(SettingKeys.deviceName), 'Mine');
    await a.close();
  });

  test('outbox sender_identity and route are frozen', () async {
    final a = await _open();
    final repo = Repo(a);
    final chat = await repo.findOrCreateChat('B', 'cc' * 16);
    final ids = await repo.insertOutgoing(
      identity: 'B',
      chatId: chat,
      destinationHash: 'cc' * 16,
      text: 'x',
      route: 'opportunistic',
      transport: 'none',
    );
    final ob = await repo.outbox(ids.outboxId);
    expect((ob!.sender, ob.route), ('B', 'opportunistic'));
    await expectLater(
      a.db.update(
        'outbox',
        {'sender_identity': 'A'},
        where: 'id = ?',
        whereArgs: [ids.outboxId],
      ),
      throwsA(anything),
    );
    await expectLater(
      a.db.update(
        'outbox',
        {'route': 'via_bridge'},
        where: 'id = ?',
        whereArgs: [ids.outboxId],
      ),
      throwsA(anything),
    );
    // Other columns remain writable.
    await repo.outboxSave(
      id: ids.outboxId,
      lxmfHash: 'ff',
      packed: Uint8List.fromList([1, 2, 3]),
      attempts: 2,
      state: 4,
    );
    final row = (await repo.outboxPending()).single;
    expect(row['attempts'], 2);
    expect(row['sender_identity'], 'B');
    expect(row['route'], 'opportunistic');
    await a.close();
  });

  test('message hash is unique per account (dedup)', () async {
    final a = await _open();
    final repo = Repo(a);
    final chat = await repo.findOrCreateChat('B', 'dd' * 16);
    Future<int> add() => repo.insertIncoming(
      identity: 'B',
      chatId: chat,
      lxmfHash: 'same',
      text: 't',
      ts: DateTime.now(),
      route: 'direct',
      transport: 'tcp',
      signatureValid: true,
    );
    await add();
    await expectLater(add(), throwsA(anything));
    expect(await _count(a, 'messages'), 1);
    await a.close();
  });
}
