import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';

import '../node/identity_store.dart';
import '../platform.dart';
import '../storage/database.dart';
import '../storage/repo.dart';
import 'bridge_connection.dart';
import 'bridge_store.dart';
import 'codec.dart';
import 'vault_service.dart';

/// Creates the connection for the bridge identified by [publicKey].
typedef BridgeApiFactory = BridgeApi Function(
  Uint8List publicKey,
  AllowFallback allowFallback,
);

/// An RRC message that starts with `/` would run as a hub command as A.
class RrcCommandBlocked implements Exception {
  @override
  String toString() => 'RRC messages starting with / are blocked';
}

/// The invite QR code is long expired.
class InviteExpired implements Exception {
  @override
  String toString() => 'the invite expired';
}

/// An invite QR code ready to show: [text] is the QR content, [expiresAt]
/// when it stops working (local time).
class InviteQr {
  InviteQr(this.text, this.expiresAt);
  final String text;
  final DateTime expiresAt;
}

class BridgeNotConfigured implements Exception {
  @override
  String toString() => 'bridge is not configured';
}

/// Everything account A: connection lifecycle, sync into SQLite, push
/// handling, sending, the outbox, devices, pairing and RRC.
///
/// Writes only through [BridgeStore]/[Repo]; nothing here deletes chats or
/// messages.
class BridgeService {
  BridgeService({
    required this.repo,
    required this.ownDeviceId,
    required this.identity,
    required this.apiFactory,
    required this.sendAsB,
    this.retryResend = const Duration(seconds: 15),
    SecretStore? secrets,
    VaultService? vaultService,
  }) : store = BridgeStore(repo),
       vault =
           vaultService ??
           VaultService(
             repo: repo,
             keys: VaultKeys(secrets ?? MemorySecretStore()),
             identity: identity,
             ownDeviceId: ownDeviceId,
           );

  final Repo repo;
  final BridgeStore store;

  /// End-to-end encrypted sync of this device's Standalone history.
  final VaultService vault;

  /// This device's id (hash of identity B).
  final String Function() ownDeviceId;
  final Identity Function() identity;
  final BridgeApiFactory apiFactory;

  /// Sends [text] in the B chat [chatId] (NodeService.sendMessage).
  final Future<int> Function(int chatId, String text) sendAsB;
  final Duration retryResend;

  BridgeApi? _api;
  final _status = StreamController<BridgeStatus>.broadcast();
  BridgeStatus _statusNow = const BridgeStatus(BridgeState.off);
  final List<StreamSubscription<Object?>> _subs = [];
  Future<void> _tail = Future.value();
  final Set<int> _inflight = {};
  final Set<int> _loggedUnreachable = {};
  final LinkedHashSet<String> _seen = LinkedHashSet();
  bool _flushing = false;
  bool _syncing = false;
  Timer? _retry;
  Timer? _upstreamRetry;
  bool? _fallbackSetting;
  bool _ownField = false;
  bool _stopped = false;

  BridgeStatus get status => _statusNow;
  Stream<BridgeStatus> get statusChanges => _status.stream;
  BridgeApi? get api => _api;

  /// Whether commands may go out as LXMF when there is no Link: the user's
  /// setting, default on for devices with the `field` role.
  bool get fallbackEnabled => _fallbackSetting ?? _ownField;

  // --------------------------------------------------------------- lifecycle

  void _chain(Future<void> Function() f) {
    _tail = _tail.then((_) => f()).catchError((Object _) {});
  }

  /// Waits for queued event handlers (tests).
  Future<void> flushEvents() async {
    await Future<void>.delayed(Duration.zero);
    await _tail;
  }

  void _emit(BridgeStatus s) {
    if (s == _statusNow) return;
    _statusNow = s;
    if (!_status.isClosed) _status.add(s);
  }

  Future<String?> configuredKey() async {
    final k = await repo.getSetting(SettingKeys.bridgePubkey);
    return (k == null || k.length != 128) ? null : k;
  }

  Future<bool> isRevoked() async =>
      (await repo.getSetting(SettingKeys.bridgeRevoked)) == '1';

  /// Starts the connection if bridge mode is on and configured.
  Future<void> start() async {
    final fb = await repo.getSetting(SettingKeys.bridgeLxmfFallback);
    _fallbackSetting = fb == null ? null : fb == '1';
    _ownField =
        (await repo.getSetting(SettingKeys.bridgeOwnRoles))
            ?.contains('field') ??
        false;
    if (await isRevoked()) {
      _emit(const BridgeStatus(BridgeState.revoked, detail: 'device_revoked'));
      return;
    }
    if (!await repo.bridgeEnabled()) return;
    final key = await configuredKey();
    if (key == null) return;
    await _attach(key);
  }

  Future<void> _attach(String keyHex, {InvitePayload? redeem}) async {
    await _detach();
    final api = apiFactory(
      Uint8List.fromList(fromHex(keyHex)),
      () => fallbackEnabled,
    );
    _api = api;
    _emit(api.status);
    _subs
      ..add(api.statusChanges.listen(_onApiStatus))
      ..add(api.pushes.listen((e) => _chain(() => _onPush(e))))
      ..add(api.connected.listen((h) => _chain(() => _onConnected(h))));
    api.setIdentityInfo(await deviceName(), platformId());
    await vault.attach(api, keyHex);
    if (redeem == null) await api.start();
  }

  /// The device name the user chose (or the platform default). The app owns
  /// it: it is sent with every `/hello` and shown in "My devices".
  Future<String> deviceName() async {
    final n = (await repo.getSetting(SettingKeys.deviceName))?.trim();
    return (n == null || n.isEmpty) ? defaultDeviceName() : n;
  }

  /// Settings -> device name: stores it and tells the bridge right away
  /// (otherwise the next `/hello` does).
  Future<void> setDeviceName(String name) async {
    final v = name.trim().isEmpty ? defaultDeviceName() : name.trim();
    await repo.setSetting(SettingKeys.deviceName, v);
    final api = _api;
    if (api == null) return;
    api.setIdentityInfo(v, platformId());
    if (!api.linkUp) return;
    try {
      final r = await api.call('/devices/rename', {'name': v});
      await store.upsertDevices([DeviceRecord.fromMap(asMap(r['device']))]);
    } on BridgeError catch (e) {
      _noteError(e);
    } on BridgeTransportError {
      // the next /hello carries the new name
    }
  }

  /// A `device_revoked` reason from the bridge (spec 2.4) is handled like the
  /// push: forget the credentials and stop for good.
  void _onApiStatus(BridgeStatus s) {
    _emit(s);
    if (s.state == BridgeState.revoked) {
      _chain(() async {
        if (!await isRevoked()) await _handleRevoked();
      });
    }
  }

  Future<void> _detach() async {
    _retry?.cancel();
    _upstreamRetry?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await vault.detach();
    final a = _api;
    _api = null;
    await a?.stop();
    _emit(const BridgeStatus(BridgeState.off));
  }

  /// Stores the bridge public key (pasted text or QR: the first 128 hex
  /// characters are used), turns bridge mode on and connects. Throws
  /// [FormatException] if no key is found.
  Future<void> configure(String text) async {
    final key = extractBridgePublicKey(text);
    if (key == null) {
      throw const FormatException('no bridge public key (128 hex) found');
    }
    final old = await repo.getSetting(SettingKeys.bridgePubkey);
    if (old != null && old != key) {
      // another bridge: its cursors mean nothing here (data stays)
      await store.resetCursors();
      await repo.setSetting(SettingKeys.bridgeStateId, '');
    }
    await repo.setSetting(SettingKeys.bridgePubkey, key);
    await repo.setSetting(SettingKeys.bridgeRevoked, '0');
    await repo.setBridgeEnabled(true);
    await _attach(key);
  }

  /// The mode switch. Off = [turnOff] (account A is dropped, nothing is
  /// kept running); on = connect and sync from scratch.
  Future<void> setEnabled(bool on) async {
    if (!on) {
      await turnOff();
      return;
    }
    await repo.setBridgeEnabled(true);
    final key = await configuredKey();
    if (key != null && !await isRevoked()) await _attach(key);
  }

  /// How many typed-but-unsent account A messages exist (the confirmation
  /// dialog tells the user they are lost when the bridge goes off).
  Future<int> queuedSendCount() async =>
      (await store.queuedAMessageIds()).length;

  /// Turns the bridge off: stops the connection completely (no background
  /// reconnects), then removes account A's local data in one transaction.
  /// Account A is only a cache of MeshChatX, which keeps the history; the
  /// pairing (identity, bridge address, trusted status) is kept, so turning
  /// the bridge on again syncs everything back without re-pairing.
  ///
  /// Unsent A messages are discarded, unless [sendQueuedFromB] is set: then
  /// each one is first re-sent as a NEW message from this device (B), the
  /// user's explicit choice.
  Future<void> turnOff({bool sendQueuedFromB = false}) async {
    if (sendQueuedFromB) {
      for (final id in await store.queuedAMessageIds()) {
        await sendFromBInstead(id);
      }
    }
    await repo.setBridgeEnabled(false);
    await _detach();
    await flushEvents(); // nothing from the old connection writes after this
    await repo.purgeBridgeAccountData();
  }

  /// True while a sync from the bridge is running (progress indicator).
  bool get syncing => _syncing;
  Stream<bool> get syncingChanges => _syncCtl.stream;
  final _syncCtl = StreamController<bool>.broadcast();

  Future<void> setFallback(bool on) async {
    _fallbackSetting = on;
    await repo.setSetting(SettingKeys.bridgeLxmfFallback, on ? '1' : '0');
    _emit(
      BridgeStatus(
        _statusNow.state,
        detail: _statusNow.detail,
        fallback: on && (_api?.canFallback ?? false),
        hello: _statusNow.hello,
      ),
    );
    unawaited(_flush());
  }

  Future<void> stop() async {
    _stopped = true;
    await _detach();
    await _status.close();
    await _syncCtl.close();
  }

  /// Offers an inbound LXMF message to the bridge connection; true if it was
  /// a service message from the bridge (never shown as a chat message).
  bool handleLxmf(LXMessage m) {
    final a = _api;
    return a is BridgeConnection && a.handleLxmf(m);
  }

  // ------------------------------------------------------------ connect/sync

  Future<void> _onConnected(HelloResult h) async {
    _ownField = h.device.isField;
    await repo.setSetting(SettingKeys.bridgeOwnRoles, h.device.roles.join(','));
    await repo.setSetting(
      SettingKeys.bridgeClockOffset,
      '${h.time - DateTime.now().millisecondsSinceEpoch / 1000}',
    );
    await store.upsertDevices([h.device]);
    await resync(helloStateId: h.stateId);
    await refreshDevices();
    await refreshRooms();
    await _flush();
    unawaited(vault.onConnected(h));
  }

  /// Pulls every conversation change since the stored cursor.
  Future<void> resync({String? helloStateId}) async {
    final api = _api;
    if (api == null || _syncing) return;
    _syncing = true;
    if (!_syncCtl.isClosed) _syncCtl.add(true);
    try {
      var cursor = await store.cursor();
      var stateId = await store.stateId();
      if (stateId != null &&
          stateId.isNotEmpty &&
          helloStateId != null &&
          helloStateId != stateId) {
        await store.resetCursors();
        cursor = 0;
        stateId = null;
      }
      while (true) {
        final m = await api.call('/sync_chats', {
          'cursor': cursor,
          'limit': 100,
          if (stateId != null && stateId.isNotEmpty) 'state_id': stateId,
        });
        final r = SyncResult.fromMap(m);
        if (stateId != null &&
            stateId.isNotEmpty &&
            r.stateId.isNotEmpty &&
            r.stateId != stateId) {
          // bridge database recreated: start over
          await store.resetCursors();
          cursor = 0;
          stateId = r.stateId;
          continue;
        }
        for (final c in r.lxmf) {
          final chatId = await store.applySummary(c);
          await _fetchConversation(chatId, c.peer);
        }
        if (r.rrc.isNotEmpty) await store.upsertRooms(r.rrc);
        cursor = r.cursor;
        stateId = r.stateId;
        // persisted only after the changes were applied (re-applying is idempotent)
        await store.saveCursor(cursor, stateId);
        if (!r.more) break;
      }
      if (_statusNow.detail == 'upstream_unavailable' && _statusNow.connected) {
        _emit(
          BridgeStatus(
            BridgeState.connected,
            fallback: _statusNow.fallback,
            hello: _statusNow.hello,
          ),
        );
      }
    } on BridgeError catch (e) {
      _noteError(e);
    } on BridgeTransportError {
      // the link will drop and reconnect; resync runs again then
    } finally {
      _syncing = false;
      if (!_syncCtl.isClosed) _syncCtl.add(false);
    }
  }

  void _noteError(BridgeError e) {
    if (e.code == 'device_revoked') unawaited(_handleRevoked());
    if (e.code == 'upstream_unavailable') {
      // The bridge is starting or MeshChatX is not reachable yet (spec: not an
      // incompatibility): show it and try again after `retry_after`.
      final st = _statusNow;
      if (st.connected) {
        _emit(
          BridgeStatus(
            BridgeState.connected,
            detail: 'upstream_unavailable',
            fallback: st.fallback,
            hello: st.hello,
          ),
        );
      }
      _upstreamRetry?.cancel();
      final d = Duration(
        milliseconds: ((e.retryAfter ?? 10) * 1000).ceil() + 250,
      );
      _upstreamRetry = Timer(d, () {
        if (!_stopped) _chain(() => resync());
      });
    }
  }

  /// Fetches new messages of one conversation (catch-up after the stored
  /// highest id, tail for a new one) and refreshes open outgoing states.
  Future<void> _fetchConversation(int chatId, String peer) async {
    final chat = await repo.chat(chatId);
    final last = chat?.bridgeLastId;
    if (last == null) {
      final r = MessagesResult.fromMap(
        await _api!.call('/get_messages', {'peer': peer, 'limit': 50}),
      );
      for (final m in r.messages) {
        await store.upsertMessage(chatId, m);
      }
      if (!r.hasMore) await store.setOlderDone(chatId, true);
      return;
    }
    var after = last;
    var gap = false;
    while (true) {
      final r = MessagesResult.fromMap(
        await _api!.call('/get_messages', {
          'peer': peer,
          'after_id': after,
          'limit': 100,
        }),
      );
      for (final m in r.messages) {
        await store.upsertMessage(chatId, m);
        if (m.id != null && m.id! > after) after = m.id!;
      }
      gap = gap || r.gap;
      if (!r.hasMore || r.messages.isEmpty) break;
    }
    if (gap || await store.hasOpenOutgoing(chatId)) {
      // a delivery-state change only marks the conversation changed (spec 6.2)
      final r = MessagesResult.fromMap(
        await _api!.call('/get_messages', {'peer': peer, 'limit': 50}),
      );
      for (final m in r.messages) {
        await store.upsertMessage(chatId, m);
      }
    }
  }

  /// Pages back in a chat; returns true if there may be more.
  Future<bool> loadOlder(int chatId) async {
    final api = _api;
    final chat = await repo.chat(chatId);
    if (api == null || chat?.peerHash == null) return false;
    final before = await store.minBridgeId(chatId);
    final r = MessagesResult.fromMap(
      await api.call('/get_messages', {
        'peer': chat!.peerHash,
        'limit': 50,
        'before_id': ?before,
      }),
    );
    for (final m in r.messages) {
      await store.upsertMessage(chatId, m);
    }
    if (!r.hasMore) await store.setOlderDone(chatId, true);
    return r.hasMore;
  }

  /// Opening an A chat: clears the local unread flag and tells the bridge.
  Future<void> markRead(int chatId) async {
    final chat = await repo.chat(chatId);
    if (chat == null || chat.accountIdentity != 'A' || chat.peerHash == null) {
      return;
    }
    final wasUnread = chat.unread > 0;
    await store.setChatUnread(chatId, false);
    final api = _api;
    if (!wasUnread || api == null) return;
    try {
      await api.call('/mark_read', {'peer': chat.peerHash});
    } on Object {
      // best effort: the next sync shows the truth
    }
  }

  // -------------------------------------------------------------------- push

  Future<void> _onPush(PushEvent e) async {
    if (e.id.isNotEmpty) {
      if (!_seen.add(e.id)) return;
      if (_seen.length > 1000) _seen.remove(_seen.first);
    }
    final d = e.data;
    switch (e.event) {
      case 'lxmf.message':
        final m = BridgeMessage.fromMap(d);
        final isNew = !await repo.hasMessageHash('A', m.hash);
        final chatId = await store.ensureChat(
          (d['peer'] as String?) ?? '',
          name: m.name,
        );
        await store.upsertMessage(chatId, m);
        if (isNew && m.incoming) await store.setChatUnread(chatId, true);
      case 'lxmf.state':
        final known = await store.applyState(
          hash: d['hash'] as String?,
          cmdId: d['cmd_id'] as String?,
          state: (d['state'] as String?) ?? '',
          method: d['method'] as String?,
        );
        if (!known) unawaited(Future(() => resync()));
      case 'read_state':
        final id = await store.chatIdForPeer((d['peer'] as String?) ?? '');
        if (id != null) await store.setChatUnread(id, false);
      case 'rrc.message':
        final hub = d['hub'] as String?;
        final room = d['room'] as String?;
        if (hub == null || room == null) return;
        final m = RrcMessage.fromMap(d);
        await store.insertRrcMessages(hub, room, [m]);
        await store.bumpRoom(hub, room, mention: m.mention);
      case 'rrc.change':
        await refreshRooms();
      case 'device_added' || 'device_updated':
        if (d['device'] is Map) {
          final rec = DeviceRecord.fromMap(asMap(d['device']));
          await store.upsertDevices([rec]);
          await _adoptOwnName(rec);
        }
      case 'vault.blob':
        unawaited(vault.onBlobPush());
      case 'device_revoked':
        if (d['device_id'] == ownDeviceId()) {
          await _handleRevoked();
        } else {
          await refreshDevices();
          // the revoking device rotated the group key (spec 9.2)
          unawaited(vault.onKeysMayHaveChanged());
        }
      case 'resync':
        await resync();
    }
  }

  /// This device was revoked: forget the bridge credentials, stop for good.
  /// Chats and messages stay (modes never erase data).
  Future<void> _handleRevoked() async {
    await repo.setSetting(SettingKeys.bridgeRevoked, '1');
    await repo.setSetting(SettingKeys.bridgePubkey, '');
    await repo.setSetting(SettingKeys.bridgeStateId, '');
    await repo.setSetting(SettingKeys.bridgeCursor, '0');
    await vault.forgetKeys();
    _api?.markRevoked();
    _emit(const BridgeStatus(BridgeState.revoked, detail: 'device_revoked'));
  }

  // ----------------------------------------------------------------- sending

  bool get _canSendNow =>
      (_api?.linkUp ?? false) || (_api?.canFallback ?? false);

  /// Queues [text] as A in A chat [chatId]. The outbox row freezes sender A
  /// and route `via_bridge`; nothing is sent before it is stored.
  Future<int> sendMessage(int chatId, String text) async {
    final chat = await repo.chat(chatId);
    if (chat == null || chat.peerHash == null) throw StateError('unknown chat');
    if (chat.accountIdentity != 'A') throw StateError('not an A chat');
    final ids = await repo.insertOutgoing(
      identity: 'A',
      chatId: chatId,
      destinationHash: chat.peerHash!,
      text: text,
      route: 'via_bridge',
      transport: 'none',
      cmdId: newCmdId(),
      originDevice: ownDeviceId(),
    );
    if (!_canSendNow && _loggedUnreachable.add(ids.messageId)) {
      await repo.addLog(ids.messageId, 'bridge_unreachable');
    }
    unawaited(_flush());
    return ids.messageId;
  }

  /// Sends everything queued for the bridge, in order.
  Future<void> _flush() async {
    if (_flushing || _stopped) return;
    _flushing = true;
    try {
      for (final q in await store.queuedSends()) {
        final api = _api;
        if (api == null || !_canSendNow) return;
        if (_inflight.contains(q.messageId)) continue;
        _inflight.add(q.messageId);
        try {
          await repo.addLog(q.messageId, 'sent_to_bridge');
          final res = await api.call('/send_lxmf', {
            'cmd_id': q.cmdId,
            'to': q.peer,
            'text': q.text,
            'delivery_method': null,
          });
          await _accepted(q, res);
        } on BridgeError catch (e) {
          final cached = e.code == 'replay' ? e.details['cached'] : null;
          if (cached is Map &&
              cached['ok'] == true &&
              cached['result'] is Map) {
            await _accepted(q, asMap(cached['result']));
          } else if (e.retryable) {
            _scheduleRetry(e.retryAfter);
            return;
          } else if (e.code == 'device_revoked') {
            await _handleRevoked();
            return;
          } else {
            await repo.updateMessage(
              q.messageId,
              status: MsgStatus.failed,
              error: e.code,
            );
            await repo.addLog(q.messageId, 'failed', detail: e.code);
            await store.outboxFinished(q.outboxId);
          }
        } on BridgeTransportError {
          _scheduleRetry(null);
          return;
        } finally {
          _inflight.remove(q.messageId);
        }
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> _accepted(QueuedBridgeSend q, Map<String, Object?> res) async {
    final state = (res['state'] as String?) ?? 'outbound';
    final method = res['method'] as String?;
    await repo.updateMessage(
      q.messageId,
      lxmfHash: res['lxmf_hash'] as String?,
      status: statusForBridgeState(state, incoming: false),
      route:
          (method == 'direct' ||
              method == 'opportunistic' ||
              method == 'propagated')
          ? method
          : null,
      transport: 'tcp',
      originDevice: ownDeviceId(),
    );
    await repo.addLog(q.messageId, 'bridge_accepted', detail: method);
    await store.outboxFinished(q.outboxId);
  }

  void _scheduleRetry(double? after) {
    _retry?.cancel();
    final d = after == null
        ? retryResend
        : Duration(milliseconds: (after * 1000).ceil() + 500);
    _retry = Timer(d, () => unawaited(_flush()));
  }

  /// Cancels a queued A message that the bridge has not accepted. False if
  /// it is already on its way (nothing can be undone then).
  Future<bool> cancelQueued(int messageId) async {
    final m = await repo.message(messageId);
    if (m == null ||
        m.senderIdentity != 'A' ||
        !m.outgoing ||
        m.status != MsgStatus.queued ||
        m.lxmfHash != null ||
        _inflight.contains(messageId)) {
      return false;
    }
    final oid = await store.outboxIdForMessage(messageId);
    await repo.updateMessage(messageId, status: MsgStatus.cancelled);
    await repo.addLog(messageId, 'cancelled');
    if (oid != null) await store.outboxFinished(oid);
    return true;
  }

  /// The explicit "send from B instead" choice: cancels the queued A message
  /// and sends the same text as a NEW message from B to the same peer. The A
  /// message keeps sender A; nothing is mutated into B. Returns the new B
  /// message id, or null if the A message could not be cancelled.
  Future<int?> sendFromBInstead(int messageId) async {
    final m = await repo.message(messageId);
    if (m == null) return null;
    final chat = await repo.chat(m.chatId);
    if (chat?.peerHash == null) return null;
    if (!await cancelQueued(messageId)) return null;
    final bChat = await repo.findOrCreateChat(
      'B',
      chat!.peerHash!,
      title: chat.title,
    );
    return sendAsB(bChat, m.text);
  }

  // ----------------------------------------------------------------- devices

  Future<List<DeviceRecord>> refreshDevices() async {
    final api = _api;
    if (api == null) return store.devices();
    try {
      final r = await api.call('/devices/list', {});
      final list = [
        for (final m in asMapList(r['devices'])) DeviceRecord.fromMap(m),
      ];
      await store.upsertDevices(list);
    } on BridgeError catch (e) {
      _noteError(e);
    } on BridgeTransportError {
      // offline: show the cached list
    }
    return store.devices();
  }

  Future<Map<String, Object?>> _admin(String path, Map<String, Object?> a) {
    final api = _api;
    if (api == null) throw BridgeNotConfigured();
    return api.call(path, a);
  }

  Future<void> renameDevice(String deviceId, String name) async {
    final r = await _admin('/devices/rename', {
      'device_id': deviceId,
      'name': name,
    });
    final rec = DeviceRecord.fromMap(asMap(r['device']));
    await store.upsertDevices([rec]);
    await _adoptOwnName(rec);
  }

  /// Settings and "My devices" must show one name: when the record of THIS
  /// device is renamed explicitly (from a trusted device: `device_updated`
  /// push or a rename response), the setting follows. A `/hello` record is
  /// not adopted: older bridges still hold the config name there.
  Future<void> _adoptOwnName(DeviceRecord rec) async {
    if (rec.deviceId != ownDeviceId() || rec.isRevoked) return;
    if ((await repo.getSetting(SettingKeys.deviceName)) == rec.name) return;
    await repo.setSetting(SettingKeys.deviceName, rec.name);
    _api?.setIdentityInfo(rec.name, platformId());
  }

  Future<void> setFieldRole(String deviceId, bool enabled) async {
    final r = await _admin('/devices/set_role', {
      'device_id': deviceId,
      'role': 'field',
      'enabled': enabled,
    });
    await store.upsertDevices([DeviceRecord.fromMap(asMap(r['device']))]);
  }

  /// Revokes a device. While the vault is in use the group key is rotated in
  /// the same request (spec 9.3): a new key for epoch + 1 wrapped for every
  /// remaining device. A concurrent revocation (`key_epoch_stale`) is retried
  /// once with fresh state.
  Future<void> revokeDevice(String deviceId, {String? reason}) async {
    Map<String, Object?> r;
    var attempt = 0;
    while (true) {
      final fields = await vault.revokeFields(deviceId);
      try {
        r = await _admin('/devices/revoke', {
          'device_id': deviceId,
          'reason': ?reason,
          ...fields.args,
        });
        await fields.commit();
        break;
      } on BridgeError catch (e) {
        if (e.code == 'key_epoch_stale' && attempt++ == 0) continue;
        rethrow;
      }
    }
    await store.upsertDevices([DeviceRecord.fromMap(asMap(r['device']))]);
    if (deviceId == ownDeviceId()) await _handleRevoked();
  }

  /// Approves the device whose pairing code was scanned or pasted. While the
  /// vault is in use the key chain is wrapped to the new device's identity;
  /// without a key this device cannot do that ([VaultKeyMissing]).
  Future<DeviceRecord> approveDevice(
    DecodedPairing d, {
    String? name,
    bool field = false,
  }) async {
    final sig = await identity().sign(pairingSignMessage(d.raw, ownDeviceId()));
    var attempt = 0;
    while (true) {
      final key = await vault.approveFields(d.payload.pubkey);
      try {
        final r = await _admin('/devices/approve', {
          'payload': d.raw,
          'signature': sig,
          if (name != null && name.isNotEmpty) 'name': name,
          if (field) 'roles': ['field'],
          ...key,
        });
        final rec = DeviceRecord.fromMap(asMap(r['device']));
        await store.upsertDevices([rec]);
        return rec;
      } on BridgeError catch (e) {
        if (e.code == 'key_epoch_stale' && attempt++ == 0) continue;
        rethrow;
      }
    }
  }

  // ----------------------------------------------------------------- pairing

  /// The code this (new) device shows. Regenerate before it expires.
  Future<PairingPayload> newPairingPayload() async {
    final name =
        (await repo.getSetting(SettingKeys.deviceName)) ?? defaultDeviceName();
    return PairingPayload(
      pubkey: identity().publicKey,
      name: name,
      platform: platformId(),
      nonce: secureRandomBytes(16),
      ts: DateTime.now().millisecondsSinceEpoch / 1000,
    );
  }

  /// TRUSTED device: asks the bridge for an invite (spec 5.4) and builds the
  /// QR text. [InviteQr.expiresAt] is in local time (bridge clock offset
  /// applied) so a countdown works even when the clocks differ.
  Future<InviteQr> createInvite() async {
    final key = await configuredKey();
    if (key == null) throw BridgeNotConfigured();
    final vf = await vault.inviteFields();
    final r = await _admin('/devices/invite', vf.args);
    final t = InviteTicket.fromMap(r);
    final offset =
        double.tryParse(
          await repo.getSetting(SettingKeys.bridgeClockOffset) ?? '',
        ) ??
        0;
    final text = encodeInviteQr(
      InvitePayload(
        bridgePubkey: Uint8List.fromList(fromHex(key)),
        token: t.token,
        inviterName: await deviceName(),
        expiresAt: t.expiresAt,
        inviteSecret: vf.secret,
      ),
    );
    return InviteQr(
      text,
      DateTime.fromMillisecondsSinceEpoch(
        ((t.expiresAt - offset) * 1000).round(),
      ),
    );
  }

  /// NEW device: configures the bridge address from the invite and redeems
  /// the token in one step. Throws [FormatException] for text that is not an
  /// invite, [InviteExpired] for an expired one, [BridgeError] when the
  /// bridge refuses it. When there was no bridge before, a failed redeem
  /// leaves the app unconfigured.
  Future<DeviceRecord> redeemInvite(String text) async {
    final inv = decodeInviteQr(text);
    if (inv.expiresAt < DateTime.now().millisecondsSinceEpoch / 1000 - 600) {
      // clocks may differ, so only an invite that is far in the past is
      // refused locally; the bridge has the final word
      throw InviteExpired();
    }
    final key = inv.bridgeKeyHex;
    final old = await repo.getSetting(SettingKeys.bridgePubkey);
    final hadBridge = old != null && old.length == 128;
    if (hadBridge && old != key) {
      await store.resetCursors();
      await repo.setSetting(SettingKeys.bridgeStateId, '');
    }
    await repo.setSetting(SettingKeys.bridgePubkey, key);
    await repo.setSetting(SettingKeys.bridgeRevoked, '0');
    await repo.setBridgeEnabled(true);
    await _attach(key, redeem: inv);
    await vault.rememberInviteSecret(inv.inviteSecret);
    try {
      final r = await _api!.redeem(
        token: inv.token,
        name: await deviceName(),
        platform: platformId(),
      );
      final rec = DeviceRecord.fromMap(asMap(r['device']));
      await store.upsertDevices([rec]);
      return rec;
    } on Object {
      await vault.rememberInviteSecret(null);
      if (!hadBridge) {
        await _detach();
        await repo.setSetting(SettingKeys.bridgePubkey, '');
        await repo.setBridgeEnabled(false);
      } else if (old != key) {
        await repo.setSetting(SettingKeys.bridgePubkey, old);
        await _attach(old);
      }
      rethrow;
    }
  }

  /// While a pairing code is on screen: connect and retry quickly until the
  /// trusted device has approved this one.
  Future<void> beginPairing() async {
    final key = await configuredKey();
    if (key == null) throw BridgeNotConfigured();
    await repo.setBridgeEnabled(true);
    if (_api == null) await _attach(key);
    _api!.fastRetry = true;
    _api!.retryNow();
  }

  void endPairing() {
    _api?.fastRetry = false;
  }

  // --------------------------------------------------------------------- RRC

  Future<void> refreshRooms() async {
    final api = _api;
    if (api == null) return;
    try {
      final r = await api.call('/list_rooms', {});
      final rooms = <RrcRoomSummary>[];
      for (final h in asMapList(r['hubs'])) {
        final hub = h['hub'] as String?;
        if (hub == null) continue;
        for (final room in asMapList(h['rooms'])) {
          rooms.add(
            RrcRoomSummary(
              hub: hub,
              hubName: (h['name'] as String?) ?? '',
              room: room['room']! as String,
              unread: asInt(room['unread']) ?? 0,
              mention: room['mention'] == true,
            ),
          );
        }
      }
      await store.upsertRooms(rooms);
    } on BridgeError catch (e) {
      _noteError(e);
    } on BridgeTransportError {
      // offline
    }
  }

  /// Loads the newest messages of a room (or the ones after the stored
  /// highest `seq`) into SQLite.
  Future<void> loadRoom(String hub, String room) async {
    final api = _api;
    if (api == null) return;
    final max = await store.rrcMaxSeq(hub, room);
    var tail = max == null;
    var after = max;
    while (!tail) {
      final r = await api.call('/get_room_messages', {
        'hub': hub,
        'room': room,
        'after_seq': after,
        'limit': 100,
      });
      final msgs = [
        for (final m in asMapList(r['messages'])) RrcMessage.fromMap(m),
      ];
      await store.insertRrcMessages(hub, room, msgs);
      if (r['gap'] == true) {
        tail = true;
        break;
      }
      if (r['has_more'] != true || msgs.isEmpty) break;
      after = msgs.last.seq;
    }
    if (tail) {
      final r = await api.call('/get_room_messages', {
        'hub': hub,
        'room': room,
        'limit': 50,
      });
      await store.insertRrcMessages(hub, room, [
        for (final m in asMapList(r['messages'])) RrcMessage.fromMap(m),
      ]);
    }
    await store.clearRoomUnread(hub, room);
  }

  /// Pages back in a room; returns true if there may be more.
  Future<bool> loadOlderRoom(String hub, String room) async {
    final api = _api;
    if (api == null) return false;
    final min = await store.rrcMinSeq(hub, room);
    final r = await api.call('/get_room_messages', {
      'hub': hub,
      'room': room,
      'limit': 50,
      'before_seq': ?min,
    });
    await store.insertRrcMessages(hub, room, [
      for (final m in asMapList(r['messages'])) RrcMessage.fromMap(m),
    ]);
    return r['has_more'] == true;
  }

  /// True if [text] would be run as a hub command (spec 7.1).
  static bool isRrcCommand(String text) => text.trimLeft().startsWith('/');

  Future<void> sendRrc(String hub, String room, String text) async {
    if (isRrcCommand(text)) throw RrcCommandBlocked();
    final api = _api;
    if (api == null) throw BridgeNotConfigured();
    await api.call('/send_rrc', {
      'cmd_id': newCmdId(),
      'hub': hub,
      'room': room,
      'text': text,
    });
  }
}
