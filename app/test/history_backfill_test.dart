import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/group/history_backfill.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<Repo> open() async => Repo(
    // Independent in-memory databases: with the default single instance both
    // repos would be the very same database (source == destination).
    await AppDatabase.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
      singleInstance: false,
    ),
  );

  test('history streams in batches into a fresh repo, once', () async {
    final a = await open();
    final b = await open();
    final peer = '11' * 16;
    for (var i = 0; i < 5; i++) {
      await a.applySyncedMessage({
        'hash': '${i + 10}' * 16,
        'peer': peer,
        'peer_name': 'Bob',
        'incoming': i.isEven,
        'text': 'm$i',
        'ts': 1700000000000 + i,
      });
    }
    await a.applySyncedDelete('22' * 16, 5);
    final src = AppBackfillSource(a, maxMessages: 2);
    final sink = AppBackfillSink(b);
    String? phase;
    var cursor = 0;
    var batches = 0;
    do {
      final batch = await src.read(phase, cursor);
      await sink.apply(batch.phase, batch.items);
      if (batch.phase == BackfillPhase.messages) {
        // Backfilled messages never raise unread by themselves.
        for (final c in await b.chats(accountIdentity: 'B')) {
          expect(c.unread, 0, reason: 'history is not unread');
        }
      }
      phase = batch.nextPhase;
      cursor = batch.nextCursor;
      batches++;
    } while (phase != null);
    expect(batches, greaterThan(4));
    // applying everything again changes nothing
    phase = null;
    cursor = 0;
    do {
      final batch = await src.read(phase, cursor);
      await sink.apply(batch.phase, batch.items);
      phase = batch.nextPhase;
      cursor = batch.nextCursor;
    } while (phase != null);
    final chats = await b.chats(accountIdentity: 'B');
    expect(chats.single.peerHash, peer);
    for (var i = 0; i < 5; i++) {
      expect(await b.hasMessageHash('B', '${i + 10}' * 16), isTrue);
    }
    // Only the `read` phase sets unread: the source's own counter (3 incoming
    // messages were unread there), applied once and never doubled.
    final srcChat = (await a.chats(accountIdentity: 'B')).single;
    expect(srcChat.unread, 3);
    expect(chats.single.unread, srcChat.unread);
    expect(await b.groupTombstone('22' * 16), 5);
  });
}
