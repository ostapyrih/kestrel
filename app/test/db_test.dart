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
      2,
    );
    expect(await _count(a, 'peers'), 0); // table from migration 2 exists
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

  test('no code path deletes chats or messages', () {
    final offenders = <String>[];
    for (final f
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      final re = RegExp(
        r'''(DELETE\s+FROM\s+(chats|messages|outbox|delivery_log)|\.delete\(\s*['"](chats|messages|outbox|delivery_log)['"]|DROP\s+TABLE)''',
        caseSensitive: false,
      );
      if (re.hasMatch(src)) offenders.add(f.path);
    }
    expect(offenders, isEmpty);
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
