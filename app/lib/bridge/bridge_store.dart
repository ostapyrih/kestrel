import 'package:sqflite/sqflite.dart';

import '../storage/database.dart';
import '../storage/repo.dart';
import 'codec.dart';

/// Maps a MeshChatX message state to the app's [MsgStatus].
String statusForBridgeState(String state, {required bool incoming}) {
  if (incoming) return MsgStatus.received;
  return switch (state) {
    'delivered' => MsgStatus.delivered,
    'sent' => MsgStatus.sent,
    'sending' => MsgStatus.sending,
    'generating' || 'outbound' || '' => MsgStatus.queued,
    _ => MsgStatus.failed,
  };
}

String? _validRoute(String? m) =>
    (m == 'direct' || m == 'opportunistic' || m == 'propagated') ? m : null;

class RrcRoomRow {
  RrcRoomRow(this.hub, this.hubName, this.room, this.unread, this.mention);
  final String hub;
  final String? hubName;
  final String room;
  final int unread;
  final bool mention;
}

class RrcMessageRow {
  RrcMessageRow(
    this.seq,
    this.kind,
    this.nick,
    this.text,
    this.tsMs,
    this.mention,
  );
  final int seq;
  final String? kind;
  final String? nick;
  final String text;
  final int tsMs;
  final bool mention;
}

class QueuedBridgeSend {
  QueuedBridgeSend({
    required this.outboxId,
    required this.messageId,
    required this.cmdId,
    required this.peer,
    required this.text,
  });
  final int outboxId;
  final int messageId;
  final String cmdId;
  final String peer;
  final String text;
}

/// SQL of account A (bridge). Like [Repo] it never deletes chats or
/// messages; cursor resets only forget positions.
class BridgeStore {
  BridgeStore(this.repo);
  final Repo repo;
  AppDatabase get adb => repo.adb;
  Database get _db => repo.adb.db;

  // ---------------------------------------------------------------- cursors

  Future<int> cursor() async =>
      int.tryParse(await repo.getSetting(SettingKeys.bridgeCursor) ?? '') ?? 0;

  Future<String?> stateId() => repo.getSetting(SettingKeys.bridgeStateId);

  Future<void> saveCursor(int cursor, String stateId) async {
    await repo.setSetting(SettingKeys.bridgeCursor, '$cursor');
    await repo.setSetting(SettingKeys.bridgeStateId, stateId);
  }

  /// The bridge database was recreated (`state_id` changed): forget every
  /// position. Stored chats and messages stay.
  Future<void> resetCursors() async {
    await repo.setSetting(SettingKeys.bridgeCursor, '0');
    await _db.update('chats', {'bridge_last_id': null, 'bridge_older_done': 0});
    adb.notify();
  }

  // ------------------------------------------------------------------ chats

  Future<int> ensureChat(String peer, {String? name}) async {
    final id = await repo.findOrCreateChat('A', peer, title: name);
    return id;
  }

  /// Applies one conversation of `/sync_chats`; returns the chat id.
  Future<int> applySummary(ConvSummary c) async {
    final id = await ensureChat(c.peer, name: c.name);
    final vals = <String, Object?>{'unread': c.unread ? 1 : 0};
    if (c.name.isNotEmpty) vals['title'] = c.name;
    await _db.update('chats', vals, where: 'id = ?', whereArgs: [id]);
    adb.notify();
    return id;
  }

  Future<void> setChatUnread(int chatId, bool unread) async {
    await _db.update(
      'chats',
      {'unread': unread ? 1 : 0},
      where: 'id = ?',
      whereArgs: [chatId],
    );
    adb.notify();
  }

  Future<int?> chatIdForPeer(String peer) async {
    final acc = await repo.accountId('A');
    final r = await _db.query(
      'chats',
      columns: ['id'],
      where: "account_id = ? AND kind = 'lxmf' AND peer_hash = ?",
      whereArgs: [acc, peer],
    );
    return r.isEmpty ? null : r.first['id']! as int;
  }

  Future<int?> minBridgeId(int chatId) async {
    final r = await _db.rawQuery(
      'SELECT MIN(bridge_id) AS m FROM messages WHERE chat_id = ?',
      [chatId],
    );
    return r.first['m'] as int?;
  }

  Future<void> setOlderDone(int chatId, bool done) async {
    await _db.update(
      'chats',
      {'bridge_older_done': done ? 1 : 0},
      where: 'id = ?',
      whereArgs: [chatId],
    );
    adb.notify();
  }

  /// True if the chat has outgoing messages that may still change state.
  Future<bool> hasOpenOutgoing(int chatId) async {
    final r = await _db.rawQuery(
      "SELECT 1 FROM messages WHERE chat_id = ? AND direction = 'out' "
      "AND status IN ('queued','sending','sent') AND lxmf_hash IS NOT NULL "
      'LIMIT 1',
      [chatId],
    );
    return r.isNotEmpty;
  }

  // --------------------------------------------------------------- messages

  /// Inserts or updates the message of the bridge in [chatId]. Matching is
  /// by LXMF hash, then by `cmd_id` (a locally queued message that the bridge
  /// now reports). Never creates a duplicate. Returns the local message id.
  Future<int> upsertMessage(int chatId, BridgeMessage m) async {
    final acc = await repo.accountId('A');
    final status = statusForBridgeState(m.state, incoming: m.incoming);
    final route = _validRoute(m.method);
    final tsMs = (m.ts * 1000).round();
    Map<String, Object?>? ex;
    var r = await _db.query(
      'messages',
      where: 'account_id = ? AND lxmf_hash = ?',
      whereArgs: [acc, m.hash],
    );
    if (r.isEmpty && m.cmdId != null) {
      r = await _db.query(
        'messages',
        where: 'account_id = ? AND cmd_id = ?',
        whereArgs: [acc, m.cmdId],
      );
    }
    if (r.isNotEmpty) ex = r.first;

    if (ex == null) {
      // deleted conversation: its old messages must never come back
      // (`/get_messages` pages, snapshots, late pushes)
      final cut = await _tombstoneOfChat(chatId);
      if (cut != null && tsMs <= cut) {
        return -1;
      }
    }

    late int id;
    if (ex != null) {
      id = ex['id']! as int;
      final old = ex['status']! as String;
      // A message cancelled locally keeps that decision for the local row
      // (its bridge copy cannot exist: cancel is only offered before the ack).
      final vals = <String, Object?>{
        'lxmf_hash': m.hash,
        'bridge_id': ?m.id,
        'origin_device': ?m.originDevice,
        'cmd_id': ?m.cmdId,
        'route': ?route,
        if (old != MsgStatus.cancelled) 'status': status,
        if (status == MsgStatus.failed) 'error': m.state,
      };
      await _db.update('messages', vals, where: 'id = ?', whereArgs: [id]);
      if (old != status && old != MsgStatus.cancelled) {
        await repo.addLog(id, _stage(status), detail: m.state);
      }
    } else {
      id = await _db.insert('messages', {
        'account_id': acc,
        'chat_id': chatId,
        'direction': m.incoming ? 'in' : 'out',
        'lxmf_hash': m.hash,
        'text': m.text,
        'title': m.title.isEmpty ? null : m.title,
        'ts': tsMs,
        'sender_identity': 'A',
        'route': route,
        'transport': 'tcp',
        'status': status,
        'error': status == MsgStatus.failed ? m.state : null,
        'bridge_id': m.id,
        'origin_device': m.originDevice,
        'cmd_id': m.cmdId,
      });
      await repo.addLog(id, _stage(status), detail: m.method);
    }
    await _db.rawUpdate(
      'UPDATE chats SET last_ts = MAX(COALESCE(last_ts, 0), ?), '
      'bridge_last_id = CASE WHEN ? IS NULL THEN bridge_last_id '
      'ELSE MAX(COALESCE(bridge_last_id, 0), ?) END WHERE id = ?',
      [tsMs, m.id, m.id, chatId],
    );
    adb.notify();
    return id;
  }

  Future<int?> _tombstoneOfChat(int chatId) async {
    final c = await _db.query(
      'chats',
      columns: ['peer_hash'],
      where: "id = ? AND kind = 'lxmf'",
      whereArgs: [chatId],
    );
    final peer = c.isEmpty ? null : c.first['peer_hash'] as String?;
    return peer == null ? null : repo.aTombstone(peer);
  }

  /// Removes the chat again if every message offered for it was refused by a
  /// tombstone (no empty chats).
  Future<void> dropIfEmpty(int chatId) async {
    await _db.execute('$removeEmptyChatsSql AND id = ?', [chatId]);
    adb.notify();
  }

  String _stage(String status) => switch (status) {
    MsgStatus.received => 'received',
    MsgStatus.delivered => 'delivered',
    MsgStatus.sent => 'sent',
    MsgStatus.sending => 'sending',
    MsgStatus.failed => 'failed',
    _ => 'queued',
  };

  /// Applies an `lxmf.state` push. Returns false if the message is unknown.
  Future<bool> applyState({
    String? hash,
    String? cmdId,
    required String state,
    String? method,
  }) async {
    final acc = await repo.accountId('A');
    var r = hash == null
        ? <Map<String, Object?>>[]
        : await _db.query(
            'messages',
            where: 'account_id = ? AND lxmf_hash = ?',
            whereArgs: [acc, hash],
          );
    if (r.isEmpty && cmdId != null) {
      r = await _db.query(
        'messages',
        where: 'account_id = ? AND cmd_id = ?',
        whereArgs: [acc, cmdId],
      );
    }
    if (r.isEmpty) return false;
    final id = r.first['id']! as int;
    final old = r.first['status']! as String;
    final status = statusForBridgeState(state, incoming: false);
    final route = _validRoute(method);
    await _db.update(
      'messages',
      {
        if (hash != null && r.first['lxmf_hash'] == null) 'lxmf_hash': hash,
        if (old != MsgStatus.cancelled) 'status': status,
        'route': ?route,
        if (status == MsgStatus.failed) 'error': state,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    if (old != status && old != MsgStatus.cancelled) {
      await repo.addLog(id, _stage(status), detail: state);
    }
    adb.notify();
    return true;
  }

  // ----------------------------------------------------------------- outbox

  /// Queued A sends in creation order (resumable after a restart).
  Future<List<QueuedBridgeSend>> queuedSends() async {
    final rows = await _db.rawQuery('''
SELECT o.id AS oid, o.message_id AS mid, o.cmd_id AS cmd,
       o.destination_hash AS dest, m.text AS text
FROM outbox o JOIN messages m ON m.id = o.message_id
WHERE o.sender_identity = 'A' AND o.status = 'queued'
  AND o.cmd_id IS NOT NULL AND m.status = 'queued'
ORDER BY o.id''');
    return [
      for (final r in rows)
        QueuedBridgeSend(
          outboxId: r['oid']! as int,
          messageId: r['mid']! as int,
          cmdId: r['cmd']! as String,
          peer: r['dest']! as String,
          text: r['text']! as String,
        ),
    ];
  }

  /// Account A messages that were typed but never reached the bridge: they
  /// are not on MeshChatX, so turning the bridge off would lose them.
  Future<List<int>> queuedAMessageIds() async {
    final rows = await _db.rawQuery('''
SELECT id FROM messages
WHERE sender_identity = 'A' AND direction = 'out' AND status = 'queued'
  AND lxmf_hash IS NULL
ORDER BY id''');
    return [for (final r in rows) r['id']! as int];
  }

  Future<void> outboxFinished(int outboxId) async {
    await _db.update(
      'outbox',
      {'status': 'done', 'packed': null},
      where: 'id = ?',
      whereArgs: [outboxId],
    );
  }

  Future<int?> outboxIdForMessage(int messageId) async {
    final r = await _db.query(
      'outbox',
      columns: ['id'],
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
    return r.isEmpty ? null : r.first['id']! as int;
  }

  // ---------------------------------------------------------------- devices

  Future<void> upsertDevices(List<DeviceRecord> devices) async {
    await _db.transaction((t) async {
      for (final d in devices) {
        await t.insert('bridge_devices', {
          'device_id': d.deviceId,
          'name': d.name,
          'platform': d.platform,
          'roles': d.roles.join(','),
          'bootstrap': d.bootstrap ? 1 : 0,
          'added_at': d.addedAt,
          'last_seen': d.lastSeen,
          'revoked_at': d.revokedAt,
          'online': d.online ? 1 : 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    adb.notify();
  }

  Future<List<DeviceRecord>> devices() async {
    final r = await _db.query(
      'bridge_devices',
      orderBy: 'revoked_at IS NOT NULL, added_at, device_id',
    );
    return [
      for (final m in r)
        DeviceRecord(
          deviceId: m['device_id']! as String,
          publicKey: '',
          name: m['name']! as String,
          platform: (m['platform'] as String?) ?? 'unknown',
          roles: [
            for (final x in ((m['roles'] as String?) ?? '').split(','))
              if (x.isNotEmpty) x,
          ],
          bootstrap: m['bootstrap'] == 1,
          addedAt: (m['added_at'] as num?)?.toDouble(),
          lastSeen: (m['last_seen'] as num?)?.toDouble(),
          revokedAt: (m['revoked_at'] as num?)?.toDouble(),
          online: m['online'] == 1,
        ),
    ];
  }

  // -------------------------------------------------------------------- RRC

  Future<void> upsertRooms(List<RrcRoomSummary> rooms) async {
    await _db.transaction((t) async {
      for (final r in rooms) {
        await t.insert('rrc_rooms', {
          'hub': r.hub,
          'hub_name': r.hubName,
          'room': r.room,
          'unread': r.unread,
          'mention': r.mention ? 1 : 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    adb.notify();
  }

  Future<List<RrcRoomRow>> rooms() async {
    final r = await _db.query('rrc_rooms', orderBy: 'hub, room');
    return [
      for (final m in r)
        RrcRoomRow(
          m['hub']! as String,
          m['hub_name'] as String?,
          m['room']! as String,
          (m['unread'] as int?) ?? 0,
          m['mention'] == 1,
        ),
    ];
  }

  Future<void> insertRrcMessages(
    String hub,
    String room,
    List<RrcMessage> msgs,
  ) async {
    await _db.transaction((t) async {
      for (final m in msgs) {
        await t.insert('rrc_messages', {
          'hub': hub,
          'room': room,
          'seq': m.seq,
          'kind': m.kind,
          'nick': m.nick,
          'text': m.text,
          'ts': m.tsMs,
          'mention': m.mention ? 1 : 0,
          'src': m.src,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
    adb.notify();
  }

  Future<int?> rrcMaxSeq(String hub, String room) async {
    final r = await _db.rawQuery(
      'SELECT MAX(seq) AS m FROM rrc_messages WHERE hub = ? AND room = ?',
      [hub, room],
    );
    return r.first['m'] as int?;
  }

  Future<int?> rrcMinSeq(String hub, String room) async {
    final r = await _db.rawQuery(
      'SELECT MIN(seq) AS m FROM rrc_messages WHERE hub = ? AND room = ?',
      [hub, room],
    );
    return r.first['m'] as int?;
  }

  Future<List<RrcMessageRow>> rrcMessages(String hub, String room) async {
    final r = await _db.query(
      'rrc_messages',
      where: 'hub = ? AND room = ?',
      whereArgs: [hub, room],
      orderBy: 'seq',
    );
    return [
      for (final m in r)
        RrcMessageRow(
          m['seq']! as int,
          m['kind'] as String?,
          m['nick'] as String?,
          m['text']! as String,
          m['ts']! as int,
          m['mention'] == 1,
        ),
    ];
  }

  Future<void> clearRoomUnread(String hub, String room) async {
    await _db.update(
      'rrc_rooms',
      {'unread': 0, 'mention': 0},
      where: 'hub = ? AND room = ?',
      whereArgs: [hub, room],
    );
    adb.notify();
  }

  Future<void> bumpRoom(
    String hub,
    String room, {
    required bool mention,
  }) async {
    await _db.insert('rrc_rooms', {
      'hub': hub,
      'room': room,
      'unread': 0,
      'mention': 0,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await _db.rawUpdate(
      'UPDATE rrc_rooms SET unread = unread + 1, '
      'mention = MAX(mention, ?) WHERE hub = ? AND room = ?',
      [mention ? 1 : 0, hub, room],
    );
    adb.notify();
  }
}
