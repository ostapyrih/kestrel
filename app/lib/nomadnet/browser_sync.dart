import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../storage/database.dart';

// Browser data sync (Phase N2): bookmarks, favourite nodes, per-node view
// settings and history of the NomadNet browser, kept equal on all devices of
// the user.
//
// TRANSPORT-AGNOSTIC ON PURPOSE. Everything in this file is a plain data
// model: a list of small JSON-able "ops" and the rules that merge them
// (docs/bridge-protocol.md 9.5, kind `browser`). Nothing here knows about the
// bridge vault. Today the vault uploader packs the ops into encrypted blobs;
// when phase S moves device sync to direct LXMF between the devices, the very
// same ops are carried by that transport and merged by [BrowserSyncStore.apply].
//
// Merge rules, per key, last writer wins by timestamp (ms):
//  * a tombstone is a record like any other and stays forever, so the result
//    does not depend on the order the ops arrive in (a tombstone beats an
//    older put, a newer put after a delete restores the item);
//  * equal timestamps: a tombstone wins, otherwise the larger canonical JSON
//    (any deterministic choice converges);
//  * history visits are never overwritten, only added; `history.clear` is a
//    watermark: visits with `ts <=` it are gone everywhere.

/// Vault blob kind (docs/bridge-protocol.md 9.5).
const browserBlobKind = 'browser';

/// History entries kept per device group (the newest ones).
const browserHistoryLimit = 500;

const _settingKeys = {'font_scale', 'wrap_all', 'identify'};
const _maxUrl = 2048;
const _maxText = 1024;
const _clearKey = 'h:clear';

/// True when a record with ([ts], [deleted], [canon]) replaces the stored one
/// ([curTs], [curDeleted], [curCanon]); a null [curTs] means nothing stored.
bool lwwWins({
  required int ts,
  required bool deleted,
  required String canon,
  int? curTs,
  bool curDeleted = false,
  String curCanon = '',
}) {
  if (curTs == null || ts > curTs) return true;
  if (ts < curTs) return false;
  if (deleted != curDeleted) return deleted;
  return canon.compareTo(curCanon) > 0;
}

/// JSON with sorted keys: the same op always has the same text, on any device.
String canonicalJson(Object? v) => json.encode(_sorted(v));

Object? _sorted(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => '$k').toList()..sort();
    return {for (final k in keys) k: _sorted(v[k])};
  }
  if (v is List) return [for (final x in v) _sorted(x)];
  return v;
}

/// Op builders (the record format).
abstract final class BrowserOps {
  static Map<String, Object?> bookmarkPut(
    String url,
    String title,
    int created,
    int ts,
  ) => {
    'op': 'bookmark.put',
    'url': url,
    'title': title,
    'created': created,
    'ts': ts,
  };

  static Map<String, Object?> bookmarkDel(String url, int ts) => {
    'op': 'bookmark.del',
    'url': url,
    'ts': ts,
  };

  static Map<String, Object?> favPut(String node, String name, int ts) => {
    'op': 'fav.put',
    'node': node,
    'name': name,
    'ts': ts,
  };

  static Map<String, Object?> favDel(String node, int ts) => {
    'op': 'fav.del',
    'node': node,
    'ts': ts,
  };

  static Map<String, Object?> historyAdd(String url, String title, int ts) => {
    'op': 'history.add',
    'url': url,
    'title': title,
    'ts': ts,
  };

  static Map<String, Object?> historyClear(int ts) => {
    'op': 'history.clear',
    'ts': ts,
  };

  static Map<String, Object?> settingPut(
    String node,
    String key,
    Object value,
    int ts,
  ) => {
    'op': 'node_settings.put',
    'node': node,
    'key': key,
    'value': value,
    'ts': ts,
  };
}

/// A validated op: [key] is its `browser_sync` key (null for history adds).
class _Op {
  _Op(this.name, this.map, this.key, this.ts);
  final String name;
  final Map<String, Object?> map;
  final String? key;
  final int ts;

  bool get deleted => name == 'bookmark.del' || name == 'fav.del';
}

/// Returns the op if [raw] is well formed, else null (unknown ops from a
/// newer app and malformed records are skipped, never fatal).
_Op? _parse(Object? raw) {
  if (raw is! Map) return null;
  final name = raw['op'];
  final tsRaw = raw['ts'];
  if (name is! String || tsRaw is! num || !tsRaw.isFinite || tsRaw < 0) {
    return null;
  }
  final ts = tsRaw.round();
  String? str(String k, int max, {bool empty = false}) {
    final v = raw[k];
    if (v is! String || v.length > max || (!empty && v.isEmpty)) return null;
    return v;
  }

  switch (name) {
    case 'bookmark.put':
      final url = str('url', _maxUrl);
      final title = str('title', _maxText, empty: true);
      if (url == null || title == null) return null;
      final c = raw['created'];
      final created = c is num && c.isFinite ? c.round() : ts;
      return _Op(
        name,
        BrowserOps.bookmarkPut(url, title, created, ts),
        'b:$url',
        ts,
      );
    case 'bookmark.del':
      final url = str('url', _maxUrl);
      if (url == null) return null;
      return _Op(name, BrowserOps.bookmarkDel(url, ts), 'b:$url', ts);
    case 'fav.put':
      final node = str('node', 64);
      final nm = raw['name'] is String ? raw['name']! as String : '';
      if (node == null || nm.length > _maxText) return null;
      return _Op(name, BrowserOps.favPut(node, nm, ts), 'f:$node', ts);
    case 'fav.del':
      final node = str('node', 64);
      if (node == null) return null;
      return _Op(name, BrowserOps.favDel(node, ts), 'f:$node', ts);
    case 'node_settings.put':
      final node = str('node', 64);
      final key = str('key', 32);
      final v = raw['value'];
      if (node == null || key == null || !_settingKeys.contains(key)) {
        return null;
      }
      Object value;
      if (key == 'font_scale') {
        if (v is! num || !v.isFinite || v < 0.1 || v > 10) return null;
        value = v.toDouble();
      } else {
        if (v is! bool) return null;
        value = v;
      }
      return _Op(
        name,
        BrowserOps.settingPut(node, key, value, ts),
        's:$node:$key',
        ts,
      );
    case 'history.add':
      final url = str('url', _maxUrl);
      final title = str('title', _maxText, empty: true);
      if (url == null || title == null) return null;
      return _Op(name, BrowserOps.historyAdd(url, title, ts), null, ts);
    case 'history.clear':
      return _Op(name, BrowserOps.historyClear(ts), _clearKey, ts);
  }
  return null;
}

/// An op waiting to be uploaded and the `mark` that records it as sent.
class PendingOp {
  PendingOp(this.op, this.mark);
  final Map<String, Object?> op;

  /// `['browser', key, ts]` or `['browser_h', historyId]`
  /// (see [BrowserSyncStore.completeMarks]).
  final List<Object?> mark;
}

/// SQL of the browser data sync: the local side of the merge. Local edits go
/// through [mark] (called by `NomadStore`), remote ops through [apply].
class BrowserSyncStore {
  BrowserSyncStore(this.adb);
  final AppDatabase adb;
  Database get _db => adb.db;

  static const markKind = 'browser';
  static const markHistory = 'browser_h';

  // ------------------------------------------------------------ local edits

  /// Records a local change of [key]: the op [make] builds with the new
  /// timestamp becomes the winning record and is queued for upload. The
  /// timestamp is at least one past the stored one, so a local edit always
  /// beats what this device knew before, even with a clock that runs behind.
  static Future<void> mark(
    DatabaseExecutor x,
    String key,
    Map<String, Object?> Function(int ts) make, {
    int? nowMs,
  }) async {
    final cur = await x.query(
      'browser_sync',
      columns: ['ts'],
      where: 'key = ?',
      whereArgs: [key],
    );
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final ts = cur.isEmpty
        ? now
        : (now > (cur.first['ts']! as int)
              ? now
              : (cur.first['ts']! as int) + 1);
    final op = make(ts);
    await x.insert('browser_sync', {
      'key': key,
      'ts': ts,
      'deleted': (op['op'] as String).endsWith('.del') ? 1 : 0,
      'op': canonicalJson(op),
      'dirty': 1,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// The history was cleared locally (everything up to now is gone).
  static Future<void> markHistoryCleared(DatabaseExecutor x, {int? nowMs}) =>
      mark(x, _clearKey, BrowserOps.historyClear.call, nowMs: nowMs);

  // -------------------------------------------------------------- backfill

  /// One-time import of what existed before this version: bookmarks,
  /// favourites and non-default node settings become records (insert-or-
  /// ignore: a record written by a later local edit or a remote op is never
  /// replaced). Timestamps are the oldest plausible ones (bookmark creation,
  /// node first seen), so any real edit made anywhere wins over the import.
  /// History needs no import: its rows start with `synced = 0`.
  Future<void> backfillOnce(
    Future<String?> Function(String key) getSetting,
    Future<void> Function(String key, String value) setSetting,
  ) async {
    if (await getSetting(SettingKeys.browserBackfilled) == '1') return;
    await _db.transaction((t) async {
      Future<void> put(String key, Map<String, Object?> op) =>
          t.insert('browser_sync', {
            'key': key,
            'ts': op['ts'],
            'deleted': 0,
            'op': canonicalJson(op),
            'dirty': 1,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
      for (final b in await t.query('nomad_bookmarks')) {
        final url = b['url']! as String;
        final created = b['created']! as int;
        await put(
          'b:$url',
          BrowserOps.bookmarkPut(url, b['title']! as String, created, created),
        );
      }
      for (final n in await t.query('nomad_nodes')) {
        final h = n['hash']! as String;
        final ts = n['first_seen']! as int;
        if (n['favourite'] == 1) {
          await put('f:$h', BrowserOps.favPut(h, n['name']! as String, ts));
        }
        final scale = (n['font_scale'] as num?)?.toDouble() ?? 1.0;
        if (scale != 1.0) {
          await put(
            's:$h:font_scale',
            BrowserOps.settingPut(h, 'font_scale', scale, ts),
          );
        }
        if (n['wrap_all'] == 1) {
          await put(
            's:$h:wrap_all',
            BrowserOps.settingPut(h, 'wrap_all', true, ts),
          );
        }
        if (n['identify'] == 1) {
          await put(
            's:$h:identify',
            BrowserOps.settingPut(h, 'identify', true, ts),
          );
        }
      }
    });
    await setSetting(SettingKeys.browserBackfilled, '1');
  }

  /// The bridge database was recreated: everything has to be uploaded again.
  static Future<void> markAllDirty(DatabaseExecutor x) async {
    await x.rawUpdate('UPDATE browser_sync SET dirty = 1');
    await x.rawUpdate('UPDATE nomad_history SET synced = 0');
  }

  // -------------------------------------------------------------- uploading

  /// Records changed since they were uploaded, plus history visits older than
  /// [historyMinAgeMs] (0 = all; null = none: visits are batched so browsing
  /// does not cause an upload per page). Oldest first, at most [limit].
  Future<List<PendingOp>> pending({
    required int limit,
    int? historyMinAgeMs,
    int? nowMs,
  }) async {
    final out = <PendingOp>[];
    final rows = await _db.query(
      'browser_sync',
      where: 'dirty = 1',
      orderBy: 'ts ASC',
      limit: limit,
    );
    for (final r in rows) {
      final op = json.decode(r['op']! as String);
      if (op is! Map) continue;
      out.add(
        PendingOp(op.cast<String, Object?>(), [markKind, r['key'], r['ts']]),
      );
    }
    if (out.length < limit && await historyDue(historyMinAgeMs, nowMs: nowMs)) {
      final h = await _db.query(
        'nomad_history',
        where: 'synced = 0',
        orderBy: 'ts ASC, id ASC',
        limit: limit - out.length,
      );
      for (final r in h) {
        out.add(
          PendingOp(
            BrowserOps.historyAdd(
              r['url']! as String,
              r['title']! as String,
              r['ts']! as int,
            ),
            [markHistory, r['id']],
          ),
        );
      }
    }
    return out;
  }

  /// True if history visits are waiting and the oldest is [minAgeMs] old
  /// (null: never, 0: yes).
  Future<bool> historyDue(int? minAgeMs, {int? nowMs}) async {
    if (minAgeMs == null) return false;
    final oldest = await oldestUnsyncedHistory();
    if (oldest == null) return false;
    return (nowMs ?? DateTime.now().millisecondsSinceEpoch) - oldest >=
        minAgeMs;
  }

  /// Time of the oldest history visit not uploaded yet.
  Future<int?> oldestUnsyncedHistory() async => Sqflite.firstIntValue(
    await _db.rawQuery('SELECT MIN(ts) FROM nomad_history WHERE synced = 0'),
  );

  /// Any record waiting (history visits not counted).
  Future<bool> hasDirtyRecords() async =>
      (Sqflite.firstIntValue(
            await _db.rawQuery(
              'SELECT COUNT(*) FROM browser_sync WHERE dirty = 1',
            ),
          ) ??
          0) >
      0;

  /// Marks the ops of an uploaded blob as sent (inside the caller's
  /// transaction, together with the sequence number). A record edited again
  /// since stays dirty (the timestamp no longer matches).
  static Future<int> completeMarks(
    DatabaseExecutor x,
    List<List<Object?>> marks,
  ) async {
    var n = 0;
    for (final m in marks) {
      if (m[0] == markKind) {
        await x.update(
          'browser_sync',
          {'dirty': 0},
          where: 'key = ? AND ts = ?',
          whereArgs: [m[1], m[2]],
        );
        n++;
      } else if (m[0] == markHistory) {
        await x.update(
          'nomad_history',
          {'synced': 1},
          where: 'id = ?',
          whereArgs: [m[1]],
        );
        n++;
      }
    }
    return n;
  }

  // ------------------------------------------------------------ downloading

  /// Merges the ops of another device. Order and repetition do not matter.
  /// Malformed and unknown ops are skipped. Returns how many changed this
  /// device's data.
  Future<int> apply(List<Object?> ops) async {
    var n = 0;
    await _db.transaction((t) async {
      var historyChanged = false;
      for (final raw in ops) {
        final op = _parse(raw);
        if (op == null) continue;
        if (op.name == 'history.add') {
          if (await _applyHistoryAdd(t, op)) {
            n++;
            historyChanged = true;
          }
          continue;
        }
        final canon = canonicalJson(op.map);
        final cur = await t.query(
          'browser_sync',
          columns: ['ts', 'deleted', 'op'],
          where: 'key = ?',
          whereArgs: [op.key],
        );
        final wins = lwwWins(
          ts: op.ts,
          deleted: op.deleted,
          canon: canon,
          curTs: cur.isEmpty ? null : cur.first['ts']! as int,
          curDeleted: cur.isNotEmpty && cur.first['deleted'] == 1,
          curCanon: cur.isEmpty ? '' : cur.first['op']! as String,
        );
        if (!wins) continue;
        await t.insert('browser_sync', {
          'key': op.key,
          'ts': op.ts,
          'deleted': op.deleted ? 1 : 0,
          'op': canon,
          'dirty': 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await _applyToTables(t, op);
        if (op.name == 'history.clear') historyChanged = true;
        n++;
      }
      if (historyChanged) await prune(t);
    });
    return n;
  }

  Future<bool> _applyHistoryAdd(DatabaseExecutor t, _Op op) async {
    final clear = await t.query(
      'browser_sync',
      columns: ['ts'],
      where: 'key = ?',
      whereArgs: [_clearKey],
    );
    if (clear.isNotEmpty && op.ts <= (clear.first['ts']! as int)) return false;
    final url = op.map['url']! as String;
    final dup = await t.query(
      'nomad_history',
      columns: ['id'],
      where: 'url = ? AND ts = ?',
      whereArgs: [url, op.ts],
      limit: 1,
    );
    if (dup.isNotEmpty) return false;
    await t.insert('nomad_history', {
      'url': url,
      'title': op.map['title']! as String,
      'ts': op.ts,
      'synced': 1,
    });
    return true;
  }

  Future<void> _applyToTables(DatabaseExecutor t, _Op op) async {
    final m = op.map;
    switch (op.name) {
      case 'bookmark.put':
        await t.insert('nomad_bookmarks', {
          'url': m['url'],
          'title': m['title'],
          'created': m['created'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      case 'bookmark.del':
        await t.delete(
          'nomad_bookmarks',
          where: 'url = ?',
          whereArgs: [m['url']],
        );
      case 'fav.put':
        await _ensureNode(t, m['node']! as String, op.ts);
        await t.update(
          'nomad_nodes',
          {
            'favourite': 1,
            if ((m['name']! as String).isNotEmpty) 'name': m['name'],
          },
          where: 'hash = ?',
          whereArgs: [m['node']],
        );
      case 'fav.del':
        await t.update(
          'nomad_nodes',
          {'favourite': 0},
          where: 'hash = ?',
          whereArgs: [m['node']],
        );
      case 'node_settings.put':
        final node = m['node']! as String;
        final key = m['key']! as String;
        final v = m['value']!;
        final isDefault = switch (key) {
          'font_scale' => v == 1.0,
          _ => v == false,
        };
        final exists = (await t.query(
          'nomad_nodes',
          columns: ['hash'],
          where: 'hash = ?',
          whereArgs: [node],
        )).isNotEmpty;
        if (!exists && isDefault) return;
        await _ensureNode(t, node, op.ts);
        await t.update(
          'nomad_nodes',
          {key: v is bool ? (v ? 1 : 0) : v},
          where: 'hash = ?',
          whereArgs: [node],
        );
      case 'history.clear':
        await t.delete('nomad_history', where: 'ts <= ?', whereArgs: [op.ts]);
    }
  }

  Future<void> _ensureNode(DatabaseExecutor t, String hash, int ts) => t.insert(
    'nomad_nodes',
    {'hash': hash, 'first_seen': ts, 'last_seen': ts},
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );

  /// Keeps the newest [browserHistoryLimit] history entries (by visit time).
  static Future<void> prune(DatabaseExecutor x) => x.rawDelete(
    'DELETE FROM nomad_history WHERE id NOT IN '
    '(SELECT id FROM nomad_history ORDER BY ts DESC, id DESC LIMIT ?)',
    [browserHistoryLimit],
  );
}
