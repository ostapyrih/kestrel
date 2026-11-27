import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/nomadnet/nomad_store.dart';
import 'package:kestrel/nomadnet/page_cache.dart';
import 'package:kestrel/storage/database.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const h1 = '11111111111111111111111111111111';
const h2 = '22222222222222222222222222222222';

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase adb;
  late NomadStore s;

  setUp(() async {
    adb = await AppDatabase.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    s = NomadStore(adb);
  });
  tearDown(() => adb.close());

  test('migration creates the nomad tables', () async {
    final t = (await adb.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    )).map((r) => r['name']);
    expect(
      t,
      containsAll([
        'nomad_nodes',
        'nomad_bookmarks',
        'nomad_history',
        'nomad_cache',
      ]),
    );
    expect(
      Sqflite.firstIntValue(await adb.db.rawQuery('PRAGMA user_version')),
      latestSchemaVersion,
    );
  });

  test('view prefs (zoom, wrap) default off and persist per node', () async {
    await s.upsertAnnounced(h1, name: 'Alpha', hops: 1, nowMs: 1);
    var n = (await s.node(h1))!;
    expect(n.fontScale, 1.0);
    expect(n.wrapAll, isFalse);
    await s.setViewPrefs(h1, fontScale: 1.5);
    await s.setViewPrefs(h1, wrapAll: true);
    n = (await s.node(h1))!;
    expect(n.fontScale, 1.5);
    expect(n.wrapAll, isTrue);
    await s.setViewPrefs(h1, fontScale: 1.0);
    expect((await s.node(h1))!.wrapAll, isTrue);
  });

  group('nodes', () {
    test('announce inserts, then updates keeping flags and old name', () async {
      await s.upsertAnnounced(h1, name: 'Alpha', hops: 3, nowMs: 1000);
      await s.setFavourite(h1, true);
      await s.setIdentify(h1, true);
      await s.upsertAnnounced(h1, name: '', hops: 1, nowMs: 2000);
      final n = (await s.node(h1))!;
      expect(n.name, 'Alpha');
      expect(n.hops, 1);
      expect(n.firstSeen, 1000);
      expect(n.lastSeen, 2000);
      expect(n.favourite, isTrue);
      expect(n.identify, isTrue);
      expect(n.announced, isTrue);
    });

    test('identify defaults to off, also for nodes visited by address',
        () async {
      await s.ensureNode(h2);
      final n = (await s.node(h2))!;
      expect(n.identify, isFalse);
      expect(n.announced, isFalse);
    });

    test('search by name or hash, favourites first then recent', () async {
      await s.upsertAnnounced(h1, name: 'Alpha', hops: 1, nowMs: 1);
      await s.upsertAnnounced(h2, name: 'Beta', hops: 2, nowMs: 2);
      expect((await s.nodes()).map((n) => n.name), ['Beta', 'Alpha']);
      await s.setFavourite(h1, true);
      expect((await s.nodes()).map((n) => n.name), ['Alpha', 'Beta']);
      expect((await s.nodes(search: 'bet')).map((n) => n.name), ['Beta']);
      expect((await s.nodes(search: '1111')).map((n) => n.name), ['Alpha']);
      expect((await s.nodes(favouritesOnly: true)).length, 1);
    });

    test('forget removes the node', () async {
      await s.upsertAnnounced(h1, name: 'A', hops: 1);
      await s.forgetNode(h1);
      expect(await s.node(h1), isNull);
    });
  });

  test('bookmarks are unique per URL', () async {
    await s.addBookmark('$h1:/page/a.mu', 'A');
    await s.addBookmark('$h1:/page/a.mu', 'A2');
    expect(await s.isBookmarked('$h1:/page/a.mu'), isTrue);
    final b = await s.bookmarks();
    expect(b.length, 1);
    expect(b.single.title, 'A2');
    await s.removeBookmark('$h1:/page/a.mu');
    expect(await s.bookmarks(), isEmpty);
  });

  test('history collapses consecutive duplicates and is capped', () async {
    await s.addHistory('u1', 'one');
    await s.addHistory('u1', 'one');
    await s.addHistory('u2', 'two');
    expect((await s.history()).map((e) => e.url), ['u2', 'u1']);
    for (var i = 0; i < NomadStore.historyLimit + 20; i++) {
      await s.addHistory('p$i', '');
    }
    expect((await s.history(limit: 10000)).length, NomadStore.historyLimit);
    await s.clearHistory();
    expect(await s.history(), isEmpty);
  });

  group('PageCache over sqlite', () {
    test('expiry and replacement', () async {
      var now = DateTime(2026);
      final c = PageCache(s, now: () => now);
      await c.put('u', Uint8List.fromList([1, 2]), 100);
      expect(await c.get('u'), [1, 2]);
      await c.put('u', Uint8List.fromList([3]), 100);
      expect(await c.get('u'), [3]);
      now = now.add(const Duration(seconds: 101));
      expect(await c.get('u'), isNull);
      expect(await s.read('u'), isNull, reason: 'expired entry is removed');
    });

    test('zero seconds stores nothing and drops an older entry', () async {
      final c = PageCache(s);
      await c.put('u', Uint8List.fromList([1]), 60);
      await c.put('u', Uint8List.fromList([2]), 0);
      expect(await c.get('u'), isNull);
    });

    test('purgeExpired', () async {
      var now = DateTime(2026);
      final c = PageCache(s, now: () => now);
      await c.put('a', Uint8List.fromList([1]), 10);
      await c.put('b', Uint8List.fromList([1]), 1000);
      now = now.add(const Duration(seconds: 11));
      await c.purgeExpired();
      expect(await s.read('a'), isNull);
      expect(await s.read('b'), isNotNull);
    });
  });

  test('MemoryPageCacheStore behaves like the sqlite one', () async {
    final c = PageCache(MemoryPageCacheStore());
    await c.put('u', Uint8List.fromList([9]), 5);
    expect(await c.get('u'), [9]);
    await c.remove('u');
    expect(await c.get('u'), isNull);
  });
}
