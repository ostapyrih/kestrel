import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../storage/database.dart';
import 'page_cache.dart';

class NomadNodeRow {
  NomadNodeRow({
    required this.hash,
    required this.name,
    required this.hops,
    required this.firstSeen,
    required this.lastSeen,
    required this.announced,
    required this.favourite,
    required this.identify,
    this.fontScale = 1.0,
    this.wrapAll = false,
  });

  factory NomadNodeRow.fromMap(Map<String, Object?> m) => NomadNodeRow(
    hash: m['hash']! as String,
    name: m['name']! as String,
    hops: m['hops'] as int?,
    firstSeen: m['first_seen']! as int,
    lastSeen: m['last_seen']! as int,
    announced: (m['announced']! as int) == 1,
    favourite: (m['favourite']! as int) == 1,
    identify: (m['identify']! as int) == 1,
    fontScale: (m['font_scale'] as num?)?.toDouble() ?? 1.0,
    wrapAll: (m['wrap_all'] as int?) == 1,
  );

  final String hash;
  final String name;
  final int? hops;
  final int firstSeen;
  final int lastSeen;

  /// True if learned from an announce (false: only visited by address).
  final bool announced;
  final bool favourite;

  /// "Identify to this node" (reveals the device identity); default off.
  final bool identify;

  /// Page zoom multiplier on top of fit-to-width (1.0 = fit).
  final double fontScale;

  /// "Wrap long lines": wrap structural lines too.
  final bool wrapAll;

  String get title => name.isEmpty ? hash : name;
}

class NomadBookmark {
  NomadBookmark(this.id, this.url, this.title, this.created);
  final int id;
  final String url;
  final String title;
  final int created;
}

class NomadHistoryEntry {
  NomadHistoryEntry(this.id, this.url, this.title, this.ts);
  final int id;
  final String url;
  final String title;
  final int ts;
}

/// SQL of the NomadNet browser: nodes, bookmarks, history and the page
/// cache storage.
class NomadStore implements PageCacheStore {
  NomadStore(this.adb);
  final AppDatabase adb;
  Database get _db => adb.db;

  /// Runs [query] now and after every database change.
  Stream<T> watch<T>(Future<T> Function() query) async* {
    yield await query();
    await for (final _ in adb.changes) {
      yield await query();
    }
  }

  // -------------------------------------------------------------------- nodes

  /// Records an announce: inserts the node or updates name/hops/last seen
  /// (favourite and identify flags are kept). An empty announced name keeps
  /// a previously known name.
  Future<void> upsertAnnounced(
    String hash, {
    required String name,
    required int hops,
    int? nowMs,
  }) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((t) async {
      final r = await t.query(
        'nomad_nodes',
        where: 'hash = ?',
        whereArgs: [hash],
        limit: 1,
      );
      if (r.isEmpty) {
        await t.insert('nomad_nodes', {
          'hash': hash,
          'name': name,
          'hops': hops,
          'first_seen': now,
          'last_seen': now,
          'announced': 1,
        });
      } else {
        await t.update(
          'nomad_nodes',
          {
            if (name.isNotEmpty) 'name': name,
            'hops': hops,
            'last_seen': now,
            'announced': 1,
          },
          where: 'hash = ?',
          whereArgs: [hash],
        );
      }
    });
    adb.notify();
  }

  /// Makes sure a row exists for a node visited by address.
  Future<void> ensureNode(String hash, {int? nowMs}) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    await _db.insert('nomad_nodes', {
      'hash': hash,
      'first_seen': now,
      'last_seen': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    adb.notify();
  }

  Future<NomadNodeRow?> node(String hash) async {
    final r = await _db.query(
      'nomad_nodes',
      where: 'hash = ?',
      whereArgs: [hash],
      limit: 1,
    );
    return r.isEmpty ? null : NomadNodeRow.fromMap(r.first);
  }

  /// Nodes, favourites first, most recently announced next.
  Future<List<NomadNodeRow>> nodes({String? search, bool? favouritesOnly}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (search != null && search.trim().isNotEmpty) {
      where.add('(name LIKE ? OR hash LIKE ?)');
      final q = '%${search.trim()}%';
      args
        ..add(q)
        ..add(q);
    }
    if (favouritesOnly ?? false) where.add('favourite = 1');
    final r = await _db.query(
      'nomad_nodes',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args,
      orderBy: 'favourite DESC, last_seen DESC',
    );
    return [for (final m in r) NomadNodeRow.fromMap(m)];
  }

  Future<void> setFavourite(String hash, bool v) async {
    await ensureNode(hash);
    await _db.update(
      'nomad_nodes',
      {'favourite': v ? 1 : 0},
      where: 'hash = ?',
      whereArgs: [hash],
    );
    adb.notify();
  }

  Future<void> setIdentify(String hash, bool v) async {
    await ensureNode(hash);
    await _db.update(
      'nomad_nodes',
      {'identify': v ? 1 : 0},
      where: 'hash = ?',
      whereArgs: [hash],
    );
    adb.notify();
  }

  /// Saves the page zoom and "wrap long lines" of a node.
  Future<void> setViewPrefs(
    String hash, {
    double? fontScale,
    bool? wrapAll,
  }) async {
    await ensureNode(hash);
    await _db.update(
      'nomad_nodes',
      {
        'font_scale': ?fontScale,
        if (wrapAll != null) 'wrap_all': wrapAll ? 1 : 0,
      },
      where: 'hash = ?',
      whereArgs: [hash],
    );
    adb.notify();
  }

  Future<void> forgetNode(String hash) async {
    await _db.delete('nomad_nodes', where: 'hash = ?', whereArgs: [hash]);
    adb.notify();
  }

  // ---------------------------------------------------------------- bookmarks

  Future<void> addBookmark(String url, String title, {int? nowMs}) async {
    await _db.insert('nomad_bookmarks', {
      'url': url,
      'title': title,
      'created': nowMs ?? DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    adb.notify();
  }

  Future<void> removeBookmark(String url) async {
    await _db.delete('nomad_bookmarks', where: 'url = ?', whereArgs: [url]);
    adb.notify();
  }

  Future<bool> isBookmarked(String url) async =>
      Sqflite.firstIntValue(
        await _db.rawQuery(
          'SELECT COUNT(*) FROM nomad_bookmarks WHERE url = ?',
          [url],
        ),
      )! >
      0;

  Future<List<NomadBookmark>> bookmarks() async {
    final r = await _db.query('nomad_bookmarks', orderBy: 'created DESC');
    return [
      for (final m in r)
        NomadBookmark(
          m['id']! as int,
          m['url']! as String,
          m['title']! as String,
          m['created']! as int,
        ),
    ];
  }

  // ------------------------------------------------------------------ history

  static const historyLimit = 500;

  /// Records a visit; consecutive visits of the same URL collapse.
  Future<void> addHistory(String url, String title, {int? nowMs}) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final last = await _db.query('nomad_history', orderBy: 'id DESC', limit: 1);
    if (last.isNotEmpty && last.first['url'] == url) {
      await _db.update(
        'nomad_history',
        {'ts': now, if (title.isNotEmpty) 'title': title},
        where: 'id = ?',
        whereArgs: [last.first['id']],
      );
    } else {
      await _db.insert('nomad_history', {
        'url': url,
        'title': title,
        'ts': now,
      });
      await _db.rawDelete(
        'DELETE FROM nomad_history WHERE id <= '
        '(SELECT id FROM nomad_history ORDER BY id DESC LIMIT 1 OFFSET ?)',
        [historyLimit],
      );
    }
    adb.notify();
  }

  Future<List<NomadHistoryEntry>> history({int limit = 200}) async {
    final r = await _db.query('nomad_history', orderBy: 'id DESC', limit: limit);
    return [
      for (final m in r)
        NomadHistoryEntry(
          m['id']! as int,
          m['url']! as String,
          m['title']! as String,
          m['ts']! as int,
        ),
    ];
  }

  Future<void> clearHistory() async {
    await _db.delete('nomad_history');
    adb.notify();
  }

  // -------------------------------------------------------------- page cache

  @override
  Future<(Uint8List, int)?> read(String url) async {
    final r = await _db.query(
      'nomad_cache',
      where: 'url = ?',
      whereArgs: [url],
      limit: 1,
    );
    if (r.isEmpty) return null;
    return (
      Uint8List.fromList(r.first['data']! as List<int>),
      r.first['expires']! as int,
    );
  }

  @override
  Future<void> write(String url, Uint8List data, int expiresAtMs) => _db.insert(
    'nomad_cache',
    {'url': url, 'data': data, 'expires': expiresAtMs},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  @override
  Future<void> delete(String url) =>
      _db.delete('nomad_cache', where: 'url = ?', whereArgs: [url]);

  @override
  Future<void> deleteExpired(int nowMs) =>
      _db.delete('nomad_cache', where: 'expires <= ?', whereArgs: [nowMs]);

  Future<void> clearCache() => _db.delete('nomad_cache');
}
