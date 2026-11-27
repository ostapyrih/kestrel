import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../storage/database.dart';
import '../storage/repo.dart';

/// One of this device's own Standalone (B) messages waiting to be uploaded.
class UploadCandidate {
  UploadCandidate({
    required this.messageId,
    required this.lxmfHash,
    required this.peer,
    required this.peerName,
    required this.incoming,
    required this.title,
    required this.text,
    required this.tsMs,
    required this.status,
    required this.route,
    required this.transport,
    required this.error,
  });

  final int messageId;
  final String lxmfHash;
  final String peer;
  final String? peerName;
  final bool incoming;
  final String? title;
  final String text;
  final int tsMs;
  final String status;
  final String? route;
  final String transport;
  final String? error;
}

/// The one blob that is being uploaded, stored before the `put`.
class PendingBlob {
  PendingBlob({
    required this.blobId,
    required this.seq,
    required this.keyEpoch,
    required this.ciphertext,
    required this.marks,
  });

  final String blobId;
  final int seq;
  final int keyEpoch;
  final Uint8List ciphertext;

  /// `[messageId, status, error, lxmfHash]` of every record in the blob.
  final List<List<Object?>> marks;
}

/// First element of a pending blob mark that stands for a queued `delete_chat`
/// ([PendingBlob.marks]); the second is the `vault_delete_out` id.
const deleteMark = 'delete_chat';

/// SQL of the vault sync. Everything here only ever writes the vault
/// tables; the user's own chats and messages are read, never changed.
class VaultStore {
  VaultStore(this.repo);
  final Repo repo;
  Database get _db => repo.adb.db;

  // --------------------------------------------------------------- settings

  Future<int> _int(String key) async =>
      int.tryParse(await repo.getSetting(key) ?? '') ?? 0;

  Future<int> cursor() => _int(SettingKeys.vaultCursor);
  Future<void> saveCursor(int v) =>
      repo.setSetting(SettingKeys.vaultCursor, '$v');

  /// Last `seq` the bridge has stored for this device (confirmed by a `put`).
  Future<int> lastSeq() => _int(SettingKeys.vaultLastSeq);
  Future<void> saveLastSeq(int v) =>
      repo.setSetting(SettingKeys.vaultLastSeq, '$v');

  Future<int> gen() => _int(SettingKeys.vaultGen);

  Future<DateTime?> lastSync() async {
    final v = await _int(SettingKeys.vaultLastSync);
    return v == 0 ? null : DateTime.fromMillisecondsSinceEpoch(v);
  }

  Future<void> touchLastSync(DateTime at) => repo.setSetting(
    SettingKeys.vaultLastSync,
    '${at.millisecondsSinceEpoch}',
  );

  Future<int> usedBytes() => _int(SettingKeys.vaultUsedBytes);
  Future<int> quotaBytes() => _int(SettingKeys.vaultQuotaBytes);
  Future<bool> quotaFull() async =>
      (await repo.getSetting(SettingKeys.vaultQuotaFull)) == '1';

  Future<void> saveUsage({int? used, int? quota, bool? full}) async {
    if (used != null) {
      await repo.setSetting(SettingKeys.vaultUsedBytes, '$used');
    }
    if (quota != null) {
      await repo.setSetting(SettingKeys.vaultQuotaBytes, '$quota');
    }
    if (full != null) {
      await repo.setSetting(SettingKeys.vaultQuotaFull, full ? '1' : '0');
    }
  }

  // ------------------------------------------------------------------ reset

  /// The bridge database was recreated (new `state_id`): its vault is empty,
  /// so everything uploaded is forgotten (the next pass backfills again) and
  /// the sequence and the download position start over. Own B data stays.
  Future<void> resetForNewBridge() => repo.resetVaultForNewBridge();

  // --------------------------------------------------------------- uploading

  /// Own B messages that were never uploaded, or whose status changed since
  /// (oldest first). Only messages with a known LXMF hash take part: that
  /// hash is the key readers upsert by.
  Future<List<UploadCandidate>> candidates(int limit) async {
    final g = await gen();
    final rows = await _db.rawQuery(
      '''
SELECT m.id, m.lxmf_hash, m.direction, m.text, m.title, m.ts, m.status,
  m.route, m.transport, m.error, c.peer_hash, c.title AS peer_name
FROM messages m
JOIN accounts a ON a.id = m.account_id
JOIN chats c ON c.id = m.chat_id
LEFT JOIN vault_upload u ON u.message_id = m.id AND u.gen = ?
WHERE a.identity = 'B' AND m.lxmf_hash IS NOT NULL AND c.peer_hash IS NOT NULL
  AND (u.message_id IS NULL OR u.status != m.status
       OR COALESCE(u.error, '') != COALESCE(m.error, '')
       OR COALESCE(u.lxmf_hash, '') != m.lxmf_hash)
ORDER BY m.ts ASC, m.id ASC
LIMIT ?''',
      [g, limit],
    );
    return [
      for (final r in rows)
        UploadCandidate(
          messageId: r['id']! as int,
          lxmfHash: r['lxmf_hash']! as String,
          peer: r['peer_hash']! as String,
          peerName: r['peer_name'] as String?,
          incoming: r['direction'] == 'in',
          title: r['title'] as String?,
          text: r['text']! as String,
          tsMs: r['ts']! as int,
          status: r['status']! as String,
          route: r['route'] as String?,
          transport: r['transport']! as String,
          error: r['error'] as String?,
        ),
    ];
  }

  /// The oldest `delete_chat` still to upload (a B chat of this device was
  /// deleted after its messages had been uploaded), or null.
  Future<({int id, String peer, String? owner, int beforeTsMs})?>
  nextDelete() async {
    final r = await _db.query('vault_delete_out', orderBy: 'id ASC', limit: 1);
    if (r.isEmpty) return null;
    return (
      id: r.first['id']! as int,
      peer: r.first['peer_hash']! as String,
      owner: r.first['owner_device'] as String?,
      beforeTsMs: r.first['before_ts']! as int,
    );
  }

  /// Anything to upload: messages or queued chat deletions.
  Future<bool> hasUploadWork() async =>
      (await candidates(1)).isNotEmpty || (await nextDelete()) != null;

  Future<PendingBlob?> pending() async {
    final r = await _db.query('vault_pending', where: 'id = 1');
    if (r.isEmpty || r.first['blob_id'] == null) return null;
    final m = r.first;
    return PendingBlob(
      blobId: m['blob_id']! as String,
      seq: m['seq']! as int,
      keyEpoch: m['key_epoch']! as int,
      ciphertext: Uint8List.fromList(m['ciphertext']! as List<int>),
      marks: [
        for (final x in json.decode(m['marks']! as String) as List<Object?>)
          (x! as List<Object?>).toList(),
      ],
    );
  }

  Future<void> savePending(PendingBlob p) => _db.insert('vault_pending', {
    'id': 1,
    'blob_id': p.blobId,
    'seq': p.seq,
    'key_epoch': p.keyEpoch,
    'ciphertext': p.ciphertext,
    'marks': json.encode(p.marks),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> clearPending() => _db.delete('vault_pending');

  /// The blob [p] is stored on the bridge: the sequence advances and its
  /// records count as uploaded, in one transaction.
  Future<void> completePending(PendingBlob p) async {
    final g = await gen();
    await _db.transaction((txn) async {
      for (final m in p.marks) {
        if (m[0] == deleteMark) {
          await txn.delete(
            'vault_delete_out',
            where: 'id = ?',
            whereArgs: [m[1]],
          );
          continue;
        }
        await txn.insert('vault_upload', {
          'message_id': m[0],
          'gen': g,
          'status': m[1],
          'error': m[2],
          'lxmf_hash': m[3],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.insert('settings', {
        'key': SettingKeys.vaultLastSeq,
        'value': '${p.seq}',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete('vault_pending');
    });
  }

  // ------------------------------------------------------------ downloading

  Future<int> seen(String deviceId) async {
    final r = await _db.query(
      'vault_seen',
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
    return r.isEmpty ? 0 : r.first['last_seq']! as int;
  }

  /// Read everything again (keys arrived for blobs that were skipped).
  Future<void> rewind() async {
    await _db.delete('vault_seen');
    await saveCursor(0);
  }

  Future<void> setSeen(String deviceId, int seq) => _db.insert('vault_seen', {
    'device_id': deviceId,
    'last_seq': seq,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  /// Last `seq` read per other device (blobs downloaded from it).
  Future<Map<String, int>> seenAll() async => {
    for (final r in await _db.query('vault_seen'))
      r['device_id']! as String: r['last_seq']! as int,
  };

  Future<String?> lastError() async {
    final v = await repo.getSetting(SettingKeys.vaultLastError);
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Number of other devices whose history was downloaded.
  Future<int> remoteDeviceCount() async =>
      Sqflite.firstIntValue(
        await _db.rawQuery('SELECT COUNT(*) FROM vault_seen'),
      ) ??
      0;

  /// Applies the records of one blob of [deviceId] (upsert by LXMF hash, the
  /// later `rts` wins). Malformed records are skipped; returns how many were
  /// stored or updated.
  Future<int> applyRecords(String deviceId, List<Object?> records) async {
    var n = 0;
    await _db.transaction((txn) async {
      final tomb = <String, int?>{};
      Future<int?> tombstone(String peer) async {
        if (tomb.containsKey(peer)) return tomb[peer];
        final t = await txn.query(
          'vault_tombstones',
          columns: ['before_ts'],
          where: 'device_id = ? AND peer_hash = ?',
          whereArgs: [deviceId, peer],
        );
        return tomb[peer] = t.isEmpty ? null : t.first['before_ts']! as int;
      }

      for (final r in records) {
        if (r is! Map) continue;
        final hash = r['hash'];
        final peer = r['peer'];
        final text = r['text'];
        final ts = r['ts'];
        if (hash is! String ||
            hash.isEmpty ||
            hash.length > 64 ||
            peer is! String ||
            peer.isEmpty ||
            peer.length > 64 ||
            text is! String ||
            ts is! num) {
          continue;
        }
        final rtsRaw = r['rts'];
        final rts = rtsRaw is num ? rtsRaw.toDouble() : ts.toDouble();
        final tsMs = (ts * 1000).round();
        // removed here, or deleted by that device: older records stay away
        final cut = await tombstone(peer);
        if (cut != null && tsMs <= cut) continue;
        final peerName =
            r['peer_name'] is String && (r['peer_name'] as String).isNotEmpty
            ? r['peer_name'] as String
            : null;
        final incoming = r['incoming'] == true;
        final state = r['state'] is String
            ? r['state'] as String
            : (incoming ? MsgStatus.received : MsgStatus.sent);
        String? str(String k) => r[k] is String ? r[k] as String : null;

        final chat = await txn.query(
          'vault_chats',
          where: 'device_id = ? AND peer_hash = ?',
          whereArgs: [deviceId, peer],
        );
        final int chatId;
        if (chat.isEmpty) {
          chatId = await txn.insert('vault_chats', {
            'device_id': deviceId,
            'peer_hash': peer,
            'peer_name': peerName,
            'last_ts': tsMs,
          });
        } else {
          chatId = chat.first['id']! as int;
          final last = chat.first['last_ts'] as int?;
          await txn.update(
            'vault_chats',
            {
              'peer_name': ?peerName,
              if (last == null || tsMs > last) 'last_ts': tsMs,
            },
            where: 'id = ?',
            whereArgs: [chatId],
          );
        }
        final values = {
          'chat_id': chatId,
          'device_id': deviceId,
          'lxmf_hash': hash,
          'direction': incoming ? 'in' : 'out',
          'title': str('title'),
          'text': text,
          'ts': tsMs,
          'rts': rts,
          'status': state,
          'route': str('method'),
          'transport': str('transport') ?? 'none',
          'error': str('error'),
        };
        final ex = await txn.query(
          'vault_messages',
          columns: ['id', 'rts'],
          where: 'device_id = ? AND lxmf_hash = ?',
          whereArgs: [deviceId, hash],
        );
        if (ex.isEmpty) {
          await txn.insert('vault_messages', values);
          n++;
        } else if (rts >= (ex.first['rts']! as num).toDouble()) {
          await txn.update(
            'vault_messages',
            values,
            where: 'id = ?',
            whereArgs: [ex.first['id']],
          );
          n++;
        }
      }
    });
    if (n > 0) repo.adb.notify();
    return n;
  }
}
