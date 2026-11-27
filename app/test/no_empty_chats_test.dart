import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/storage/chat_target.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final peerB = 'aa' * 16;
final peerA = 'bb' * 16;

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

  Future<int> count(String table) async => Sqflite.firstIntValue(
    await adb.db.rawQuery('SELECT COUNT(*) FROM $table'),
  )!;

  test('looking up a conversation never creates a chat row', () async {
    expect(await repo.findChatId('B', peerB), isNull);
    expect(await repo.findChatId('A', peerA), isNull);
    expect(await repo.chats(), isEmpty);
    expect(await count('chats'), 0);
  });

  for (final identity in ['A', 'B']) {
    test('first send creates chat, message and outbox row at once '
        '($identity)', () async {
      final peer = identity == 'A' ? peerA : peerB;
      final ids = await repo.insertOutgoing(
        identity: identity,
        chatId: null,
        newChatTitle: 'Peer',
        destinationHash: peer,
        text: 'hi',
        route: identity == 'A' ? 'via_bridge' : 'opportunistic',
        transport: 'none',
      );
      expect(await count('chats'), 1);
      expect(await count('messages'), 1);
      expect(await count('outbox'), 1);
      final chat = (await repo.chat(ids.chatId))!;
      expect(chat.accountIdentity, identity);
      expect(chat.peerHash, peer);
      expect(chat.title, 'Peer');
      expect(await repo.findChatId(identity, peer), ids.chatId);
    });
  }

  test('a failing send leaves no chat behind (one transaction)', () async {
    await adb.db.execute('DROP TABLE outbox');
    await expectLater(
      repo.insertOutgoing(
        identity: 'B',
        chatId: null,
        destinationHash: peerB,
        text: 'y',
        route: 'opportunistic',
        transport: 'none',
      ),
      throwsA(anything),
    );
    expect(await repo.findChatId('B', peerB), isNull);
    expect(await count('messages'), 0);
  });

  test('an existing chat is reused by the first send', () async {
    final existing = await repo.findOrCreateChat('B', peerB, title: 'Old');
    final ids = await repo.insertOutgoing(
      identity: 'B',
      chatId: null,
      newChatTitle: 'New title',
      destinationHash: peerB,
      text: 'hi',
      route: 'opportunistic',
      transport: 'none',
    );
    expect(ids.chatId, existing);
    expect(await count('chats'), 1);
    expect((await repo.chat(existing))!.title, 'Old');
  });

  test('ChatTarget: draft vs existing', () {
    const d = ChatTarget(identity: 'B', peer: 'ab');
    expect(d.isDraft, isTrue);
    expect(d.draftKey, 'B:ab');
    expect(
      const ChatTarget(chatId: 3, identity: 'A', peer: 'ab').isDraft,
      isFalse,
    );
  });

  test('migration 8 removes empty chats, keeps chats with messages or '
      'pending outbox', () async {
    final empty = await repo.findOrCreateChat('B', 'e1' * 16);
    final emptyA = await repo.findOrCreateChat('A', 'e2' * 16);
    final withMsg = await repo.findOrCreateChat('B', 'e3' * 16);
    await repo.insertIncoming(
      identity: 'B',
      chatId: withMsg,
      lxmfHash: 'h1',
      text: 'kept',
      ts: DateTime.now(),
      route: 'direct',
      transport: 'tcp',
      signatureValid: true,
    );
    final sent = await repo.insertOutgoing(
      identity: 'A',
      chatId: null,
      destinationHash: 'e4' * 16,
      text: 'queued',
      route: 'via_bridge',
      transport: 'none',
    );
    // a chat that has only a pending outbox row (no message in this chat)
    final onlyOutbox = await repo.findOrCreateChat('B', 'e5' * 16);
    await adb.db.insert('outbox', {
      'message_id': sent.messageId,
      'account_id': await repo.accountId('B'),
      'chat_id': onlyOutbox,
      'sender_identity': 'B',
      'route': 'opportunistic',
      'destination_hash': 'e5' * 16,
      'created_ts': 1,
    });
    final room = await adb.db.insert('chats', {
      'account_id': await repo.accountId('A'),
      'kind': 'rrc',
      'room_id': 'hub/room',
    });

    await adb.db.execute(removeEmptyChatsSql);

    final left = (await adb.db.query('chats')).map((r) => r['id']).toSet();
    expect(left.contains(empty), isFalse);
    expect(left.contains(emptyA), isFalse);
    expect(left, containsAll([withMsg, sent.chatId, onlyOutbox, room]));
    expect(left, hasLength(4));
  });

  test('the migration is registered and only targets empty chats', () {
    final m8 = migrations.firstWhere((m) => m.version == 8);
    expect(m8.statements, [removeEmptyChatsSql]);
    expect(removeEmptyChatsSql, contains("kind = 'lxmf'"));
    expect(
      RegExp(r'NOT EXISTS \(SELECT 1 FROM messages')
          .hasMatch(removeEmptyChatsSql),
      isTrue,
    );
    expect(
      RegExp(r'NOT EXISTS \(SELECT 1 FROM outbox')
          .hasMatch(removeEmptyChatsSql),
      isTrue,
    );
  });
}
