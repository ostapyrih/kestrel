import 'dart:async';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import 'database.dart';

/// Delivery status shown on a message (docs/PLAN.md section 2.3).
abstract final class MsgStatus {
  static const queued = 'queued';
  static const sending = 'sending';
  static const sent = 'sent';
  static const delivered = 'delivered';
  static const failed = 'failed';
  static const received = 'received';
  static const cancelled = 'cancelled';
}

class ChatRow {
  ChatRow({
    required this.id,
    required this.accountIdentity,
    required this.kind,
    required this.peerHash,
    required this.title,
    required this.lastTs,
    required this.unread,
    this.lastText,
    this.bridgeLastId,
    this.olderDone = false,
  });

  factory ChatRow.fromMap(Map<String, Object?> m) => ChatRow(
    id: m['id']! as int,
    accountIdentity: m['identity']! as String,
    kind: m['kind']! as String,
    peerHash: m['peer_hash'] as String?,
    title: m['title'] as String?,
    lastTs: m['last_ts'] as int?,
    unread: (m['unread'] as int?) ?? 0,
    lastText: m['last_text'] as String?,
    bridgeLastId: m['bridge_last_id'] as int?,
    olderDone: (m['bridge_older_done'] as int?) == 1,
  );

  final int id;

  /// `A` or `B`.
  final String accountIdentity;
  final String kind;
  final String? peerHash;
  final String? title;
  final int? lastTs;
  final int unread;
  final String? lastText;

  /// Highest bridge (MeshChatX) message id stored for this chat (account A).
  final int? bridgeLastId;

  /// True once the bridge said there is nothing older to page back to.
  final bool olderDone;

  String get displayTitle => (title != null && title!.isNotEmpty)
      ? title!
      : (peerHash == null ? '?' : shortHash(peerHash!));
}

class MessageRow {
  MessageRow({
    required this.id,
    required this.chatId,
    required this.direction,
    required this.lxmfHash,
    required this.text,
    required this.ts,
    required this.senderIdentity,
    required this.route,
    required this.transport,
    required this.status,
    required this.error,
    required this.signatureValid,
    this.originDevice,
    this.bridgeId,
    this.cmdId,
  });

  factory MessageRow.fromMap(Map<String, Object?> m) => MessageRow(
    id: m['id']! as int,
    chatId: m['chat_id']! as int,
    direction: m['direction']! as String,
    lxmfHash: m['lxmf_hash'] as String?,
    text: m['text']! as String,
    ts: m['ts']! as int,
    senderIdentity: m['sender_identity']! as String,
    route: m['route'] as String?,
    transport: m['transport']! as String,
    status: m['status']! as String,
    error: m['error'] as String?,
    signatureValid: m['signature_valid'] == null
        ? null
        : m['signature_valid'] == 1,
    originDevice: m['origin_device'] as String?,
    bridgeId: m['bridge_id'] as int?,
    cmdId: m['cmd_id'] as String?,
  );

  final int id;
  final int chatId;
  final String direction;
  final String? lxmfHash;
  final String text;

  /// Milliseconds since epoch.
  final int ts;
  final String senderIdentity;
  final String? route;
  final String transport;
  final String status;
  final String? error;
  final bool? signatureValid;

  /// Device id that sent this message through the bridge (account A); null
  /// for incoming messages and for messages typed in the MeshChatX web UI.
  final String? originDevice;

  /// MeshChatX message id (account A).
  final int? bridgeId;

  /// Idempotency key of the bridge command that sent this message.
  final String? cmdId;

  bool get outgoing => direction == 'out';
}

class LogRow {
  LogRow(this.stage, this.ts, this.detail);
  final String stage;
  final int ts;
  final String? detail;
}

class PeerRow {
  PeerRow(this.hash, this.displayName, this.lastSeen, this.hops);
  final String hash;
  final String? displayName;
  final int lastSeen;
  final int? hops;
}

String shortHash(String h) =>
    h.length <= 12 ? h : '${h.substring(0, 6)}..${h.substring(h.length - 4)}';

/// All SQL of the app. The only code that deletes chats or messages is
/// [purgeBridgeAccountData]: account A is a cache of MeshChatX, so turning
/// the bridge off drops it; account B (this device) is never deleted.
class Repo {
  Repo(this.adb);
  final AppDatabase adb;
  Database get _db => adb.db;

  /// Runs [query] now and again after every database change.
  Stream<T> watch<T>(Future<T> Function() query) async* {
    yield await query();
    await for (final _ in adb.changes) {
      yield await query();
    }
  }

  // ----------------------------------------------------------------- settings

  Future<String?> getSetting(String key) async {
    final r = await _db.query(
      'settings',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return r.isEmpty ? null : r.first['value']! as String;
  }

  Future<void> setSetting(String key, String value) async {
    await _db.insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    adb.notify();
  }

  Future<bool> bridgeEnabled() async =>
      (await getSetting(SettingKeys.bridgeEnabled)) == '1';

  /// Mode toggle: touches only `settings`. Deleting account A's cache is a
  /// separate, explicit step ([purgeBridgeAccountData]).
  Future<void> setBridgeEnabled(bool v) =>
      setSetting(SettingKeys.bridgeEnabled, v ? '1' : '0');

  /// Turning the bridge off: removes everything that belongs to account A
  /// (chats, messages, delivery log, outbox, RRC rooms and messages, the
  /// device-list cache, sync cursors and state id; per-chat ids and read
  /// state live in the chat rows) in ONE transaction. Account B rows and the
  /// pairing (bridge address, identity) are never touched, so turning the
  /// bridge on again needs no re-pairing and simply syncs from scratch.
  Future<void> purgeBridgeAccountData() async {
    final a = await accountId('A');
    await _db.transaction((txn) async {
      await txn.rawDelete(
        'DELETE FROM delivery_log WHERE message_id IN '
        '(SELECT id FROM messages WHERE account_id = ?)',
        [a],
      );
      await txn.rawDelete('DELETE FROM outbox WHERE account_id = ?', [a]);
      await txn.rawDelete('DELETE FROM messages WHERE account_id = ?', [a]);
      await txn.rawDelete('DELETE FROM chats WHERE account_id = ?', [a]);
      await txn.delete('rrc_messages');
      await txn.delete('rrc_rooms');
      await txn.delete('bridge_devices');
      for (final e in {
        SettingKeys.bridgeStateId: '',
        SettingKeys.bridgeCursor: '0',
      }.entries) {
        await txn.insert('settings', {
          'key': e.key,
          'value': e.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    adb.notify();
  }

  // ----------------------------------------------------------------- accounts

  Future<int> accountId(String identity) async {
    final r = await _db.query(
      'accounts',
      columns: ['id'],
      where: 'identity = ?',
      whereArgs: [identity],
    );
    return r.first['id']! as int;
  }

  Future<void> setAccountAddress(
    String identity, {
    String? addressHash,
    String? displayName,
  }) async {
    await _db.update(
      'accounts',
      {'address_hash': ?addressHash, 'display_name': ?displayName},
      where: 'identity = ?',
      whereArgs: [identity],
    );
    adb.notify();
  }

  // -------------------------------------------------------------------- chats

  static const _chatSelect = '''
SELECT c.*, a.identity AS identity,
  (SELECT text FROM messages m WHERE m.chat_id = c.id
     ORDER BY m.ts DESC, m.id DESC LIMIT 1) AS last_text
FROM chats c JOIN accounts a ON a.id = c.account_id''';

  /// Chats, newest first; [accountIdentity] `A`/`B` filters, null = all.
  Future<List<ChatRow>> chats({String? accountIdentity}) async {
    final rows = await _db.rawQuery(
      '$_chatSelect ${accountIdentity == null ? '' : 'WHERE a.identity = ?'} '
      'ORDER BY COALESCE(c.last_ts, 0) DESC, c.id DESC',
      accountIdentity == null ? null : [accountIdentity],
    );
    return rows.map(ChatRow.fromMap).toList();
  }

  Future<ChatRow?> chat(int id) async {
    final rows = await _db.rawQuery('$_chatSelect WHERE c.id = ?', [id]);
    return rows.isEmpty ? null : ChatRow.fromMap(rows.first);
  }

  /// Finds or creates the LXMF chat with [peerHash] under [identity].
  Future<int> findOrCreateChat(
    String identity,
    String peerHash, {
    String? title,
  }) async {
    final acc = await accountId(identity);
    final ex = await _db.query(
      'chats',
      where: "account_id = ? AND kind = 'lxmf' AND peer_hash = ?",
      whereArgs: [acc, peerHash],
    );
    if (ex.isNotEmpty) {
      final id = ex.first['id']! as int;
      if (title != null &&
          title.isNotEmpty &&
          (ex.first['title'] as String?)?.isNotEmpty != true) {
        await _db.update(
          'chats',
          {'title': title},
          where: 'id = ?',
          whereArgs: [id],
        );
        adb.notify();
      }
      return id;
    }
    final id = await _db.insert('chats', {
      'account_id': acc,
      'kind': 'lxmf',
      'peer_hash': peerHash,
      'title': title,
    });
    adb.notify();
    return id;
  }

  Future<void> renameChat(int id, String title) async {
    await _db.update(
      'chats',
      {'title': title},
      where: 'id = ?',
      whereArgs: [id],
    );
    adb.notify();
  }

  Future<void> markRead(int chatId) async {
    await _db.update(
      'chats',
      {'unread': 0},
      where: 'id = ?',
      whereArgs: [chatId],
    );
    adb.notify();
  }

  // ----------------------------------------------------------------- messages

  Future<List<MessageRow>> messages(int chatId) async {
    final r = await _db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'ts ASC, id ASC',
    );
    return r.map(MessageRow.fromMap).toList();
  }

  Future<MessageRow?> message(int id) async {
    final r = await _db.query('messages', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : MessageRow.fromMap(r.first);
  }

  Future<bool> hasMessageHash(String identity, String lxmfHash) async {
    final r = await _db.rawQuery(
      'SELECT 1 FROM messages m JOIN accounts a ON a.id = m.account_id '
      'WHERE a.identity = ? AND m.lxmf_hash = ? LIMIT 1',
      [identity, lxmfHash],
    );
    return r.isNotEmpty;
  }

  Future<int> insertIncoming({
    required String identity,
    required int chatId,
    required String lxmfHash,
    required String text,
    String? title,
    required DateTime ts,
    required String route,
    required String transport,
    required bool signatureValid,
  }) async {
    final acc = await accountId(identity);
    final id = await _db.insert('messages', {
      'account_id': acc,
      'chat_id': chatId,
      'direction': 'in',
      'lxmf_hash': lxmfHash,
      'text': text,
      'title': title,
      'ts': ts.millisecondsSinceEpoch,
      'sender_identity': identity,
      'route': route,
      'transport': transport,
      'status': MsgStatus.received,
      'signature_valid': signatureValid ? 1 : 0,
    });
    await _db.rawUpdate(
      'UPDATE chats SET last_ts = ?, unread = unread + 1 WHERE id = ?',
      [ts.millisecondsSinceEpoch, chatId],
    );
    await addLog(id, 'received', detail: route);
    adb.notify();
    return id;
  }

  /// Queues an outgoing message: the `messages` row and the `outbox` row with
  /// the frozen sender identity and route, in one transaction.
  Future<({int messageId, int outboxId})> insertOutgoing({
    required String identity,
    required int chatId,
    required String destinationHash,
    required String text,
    String? title,
    required String route,
    required String transport,
    String? cmdId,
    String? originDevice,
  }) async {
    final acc = await accountId(identity);
    final now = DateTime.now().millisecondsSinceEpoch;
    late int mid;
    late int oid;
    await _db.transaction((t) async {
      mid = await t.insert('messages', {
        'account_id': acc,
        'chat_id': chatId,
        'direction': 'out',
        'text': text,
        'title': title,
        'ts': now,
        'sender_identity': identity,
        'route': route,
        'transport': transport,
        'status': MsgStatus.queued,
        'cmd_id': cmdId,
        'origin_device': originDevice,
      });
      oid = await t.insert('outbox', {
        'message_id': mid,
        'account_id': acc,
        'chat_id': chatId,
        'sender_identity': identity,
        'route': route,
        'destination_hash': destinationHash,
        'cmd_id': cmdId,
        'created_ts': now,
      });
      await t.update(
        'chats',
        {'last_ts': now},
        where: 'id = ?',
        whereArgs: [chatId],
      );
      await t.insert('delivery_log', {
        'message_id': mid,
        'stage': 'queued',
        'ts': now,
        'detail': route,
      });
    });
    adb.notify();
    return (messageId: mid, outboxId: oid);
  }

  Future<void> updateMessage(
    int id, {
    String? lxmfHash,
    String? status,
    String? route,
    String? transport,
    String? error,
    String? originDevice,
    int? bridgeId,
  }) async {
    final v = <String, Object?>{
      'lxmf_hash': ?lxmfHash,
      'status': ?status,
      'route': ?route,
      'transport': ?transport,
      'error': ?error,
      'origin_device': ?originDevice,
      'bridge_id': ?bridgeId,
    };
    if (v.isEmpty) return;
    await _db.update('messages', v, where: 'id = ?', whereArgs: [id]);
    adb.notify();
  }

  Future<void> addLog(
    int messageId,
    String stage, {
    String? detail,
    DateTime? at,
  }) async {
    await _db.insert('delivery_log', {
      'message_id': messageId,
      'stage': stage,
      'ts': (at ?? DateTime.now()).millisecondsSinceEpoch,
      'detail': detail,
    });
    adb.notify();
  }

  Future<List<LogRow>> log(int messageId) async {
    final r = await _db.query(
      'delivery_log',
      where: 'message_id = ?',
      whereArgs: [messageId],
      orderBy: 'ts ASC, id ASC',
    );
    return [
      for (final m in r)
        LogRow(m['stage']! as String, m['ts']! as int, m['detail'] as String?),
    ];
  }

  // ------------------------------------------------------------------- outbox

  Future<({int messageId, String sender, String route})?> outbox(int id) async {
    final r = await _db.query('outbox', where: 'id = ?', whereArgs: [id]);
    if (r.isEmpty) return null;
    return (
      messageId: r.first['message_id']! as int,
      sender: r.first['sender_identity']! as String,
      route: r.first['route']! as String,
    );
  }

  Future<void> outboxSave({
    required int id,
    required String lxmfHash,
    required Uint8List packed,
    required int attempts,
    required int state,
  }) async {
    await _db.update(
      'outbox',
      {
        'lxmf_hash': lxmfHash,
        'packed': packed,
        'attempts': attempts,
        'state': state,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> outboxDone(String lxmfHash) async {
    await _db.update(
      'outbox',
      {'status': 'done', 'packed': null},
      where: 'lxmf_hash = ?',
      whereArgs: [lxmfHash],
    );
  }

  /// Queued rows that have a packed message (resumable after a restart).
  Future<List<Map<String, Object?>>> outboxPending() =>
      _db.query('outbox', where: "status = 'queued' AND packed IS NOT NULL");

  // -------------------------------------------------------------------- peers

  Future<void> upsertPeer(
    String hash, {
    String? displayName,
    double? stampCost,
    int? hops,
  }) async {
    await _db.insert('peers', {
      'hash': hash,
      'display_name': displayName,
      'stamp_cost': stampCost,
      'hops': hops,
      'last_seen': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    adb.notify();
  }

  Future<List<PeerRow>> peers() async {
    final r = await _db.query('peers', orderBy: 'last_seen DESC');
    return [
      for (final m in r)
        PeerRow(
          m['hash']! as String,
          m['display_name'] as String?,
          m['last_seen']! as int,
          m['hops'] as int?,
        ),
    ];
  }
}
