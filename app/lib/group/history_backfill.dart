import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:sqflite/sqflite.dart';

import '../nomadnet/browser_sync.dart';
import '../storage/repo.dart';

/// Phases of the history stream a device serves to a newly paired one
/// (docs/device-sync.md, "History backfill"), in this order. Tombstones come
/// first so a deleted chat's messages are refused when they arrive.
abstract final class BackfillPhase {
  static const tombstones = 'tomb';
  static const messages = 'msg';
  static const read = 'read';
  static const browser = 'bsync';
  static const browserHistory = 'bhist';
}

/// Serves the main identity's history: chats + messages of account B (not
/// MeshChatX account A: those come from the bridge), the read state, the
/// deletion tombstones and the browser data.
class AppBackfillSource implements BackfillSource {
  AppBackfillSource(this.repo, {this.maxMessages = 40, this.maxBytes = 48000});
  final Repo repo;
  final int maxMessages;

  /// Soft cap of the text bytes of one batch (a batch is one sync record).
  final int maxBytes;

  Database get _db => repo.adb.db;

  Future<int> _count(String sql) async =>
      Sqflite.firstIntValue(await _db.rawQuery(sql)) ?? 0;

  Future<int> _total() async =>
      await _count(
        "SELECT COUNT(*) FROM vault_tombstones WHERE device_id = 'group'",
      ) +
      await _count(
        'SELECT COUNT(*) FROM messages m JOIN accounts a ON a.id = '
        "m.account_id WHERE a.identity = 'B' AND m.lxmf_hash IS NOT NULL",
      ) +
      await _count(
        'SELECT COUNT(*) FROM chats c JOIN accounts a ON a.id = c.account_id '
        "WHERE a.identity = 'B' AND c.kind = 'lxmf' AND c.unread > 0",
      ) +
      await _count('SELECT COUNT(*) FROM browser_sync') +
      await _count('SELECT COUNT(*) FROM nomad_history');

  @override
  Future<BackfillBatch> read(String? phase, int cursor) async {
    final p = phase ?? BackfillPhase.tombstones;
    final total = cursor == 0 && p == BackfillPhase.tombstones
        ? await _total()
        : null;
    switch (p) {
      case BackfillPhase.tombstones:
        final rows = await _db.query(
          'vault_tombstones',
          where: 'device_id = ?',
          whereArgs: [Repo.groupTombstoneId],
        );
        return BackfillBatch(
          phase: p,
          items: [
            for (final r in rows)
              {'peer': r['peer_hash'], 'before_ts': r['before_ts']},
          ],
          nextPhase: BackfillPhase.messages,
          total: total,
        );
      case BackfillPhase.messages:
        final rows = await _db.rawQuery(
          'SELECT m.id, m.direction, m.lxmf_hash, m.text, m.title, m.ts, '
          'm.route, m.status, c.peer_hash, c.title AS peer_name '
          'FROM messages m JOIN accounts a ON a.id = m.account_id '
          'JOIN chats c ON c.id = m.chat_id '
          "WHERE a.identity = 'B' AND m.lxmf_hash IS NOT NULL AND m.id > ? "
          'ORDER BY m.id LIMIT ?',
          [cursor, maxMessages],
        );
        final items = <Object?>[];
        var bytes = 0;
        var last = cursor;
        for (final r in rows) {
          final text = r['text']! as String;
          if (items.isNotEmpty && bytes + text.length > maxBytes) break;
          bytes += text.length;
          last = r['id']! as int;
          items.add({
            'hash': r['lxmf_hash'],
            'peer': r['peer_hash'],
            'peer_name': ?r['peer_name'],
            'incoming': r['direction'] == 'in',
            'text': text,
            'title': ?r['title'],
            'ts': r['ts'],
            'route': ?r['route'],
            'state': r['status'],
          });
        }
        final more = items.length < rows.length || rows.length == maxMessages;
        return BackfillBatch(
          phase: p,
          items: items,
          nextPhase: more ? BackfillPhase.messages : BackfillPhase.read,
          nextCursor: more ? last : 0,
          total: total,
        );
      case BackfillPhase.read:
        final rows = await _db.rawQuery(
          'SELECT c.peer_hash, c.unread FROM chats c JOIN accounts a ON '
          "a.id = c.account_id WHERE a.identity = 'B' AND c.kind = 'lxmf' "
          'AND c.unread > 0 AND c.peer_hash IS NOT NULL',
        );
        return BackfillBatch(
          phase: p,
          items: [
            for (final r in rows) {'peer': r['peer_hash'], 'unread': r['unread']},
          ],
          nextPhase: BackfillPhase.browser,
        );
      case BackfillPhase.browser:
        final rows = await _db.query(
          'browser_sync',
          columns: ['op'],
          orderBy: 'key',
          limit: 200,
          offset: cursor,
        );
        final ops = BrowserSyncStore.decodeOps(rows);
        return BackfillBatch(
          phase: p,
          items: ops,
          nextPhase: rows.length == 200
              ? BackfillPhase.browser
              : BackfillPhase.browserHistory,
          nextCursor: rows.length == 200 ? cursor + 200 : 0,
        );
      case BackfillPhase.browserHistory:
        final rows = await _db.query(
          'nomad_history',
          where: 'id > ?',
          whereArgs: [cursor],
          orderBy: 'id',
          limit: 200,
        );
        return BackfillBatch(
          phase: p,
          items: [
            for (final r in rows)
              BrowserOps.historyAdd(
                r['url']! as String,
                r['title']! as String,
                r['ts']! as int,
              ),
          ],
          nextPhase: rows.length == 200 ? BackfillPhase.browserHistory : null,
          nextCursor: rows.isEmpty ? 0 : rows.last['id']! as int,
        );
    }
    // unknown phase (a newer sibling): nothing to serve, the stream ends
    return BackfillBatch(phase: p, items: const []);
  }
}

/// Applies the history on the new device. Idempotent: messages are upserted
/// by LXMF hash, tombstones and browser ops merge.
class AppBackfillSink implements BackfillSink {
  AppBackfillSink(this.repo, {this.browser});
  final Repo repo;
  final BrowserSyncStore? browser;

  @override
  Future<void> apply(String phase, List<Object?> items) async {
    switch (phase) {
      case BackfillPhase.tombstones:
        for (final m in items) {
          if (m is Map && m['peer'] is String && m['before_ts'] is int) {
            await repo.applySyncedDelete(
              m['peer']! as String,
              m['before_ts']! as int,
            );
          }
        }
      case BackfillPhase.messages:
        for (final m in items) {
          if (m is Map) await repo.applySyncedMessage(m, history: true);
        }
      case BackfillPhase.read:
        for (final m in items) {
          if (m is Map && m['peer'] is String && m['unread'] is int) {
            await repo.applySyncedUnread(
              m['peer']! as String,
              m['unread']! as int,
            );
          }
        }
      case BackfillPhase.browser:
      case BackfillPhase.browserHistory:
        await browser?.apply(items);
    }
  }
}
