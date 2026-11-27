import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:kestrel_rns/kestrel_rns.dart';

import '../node/identity_store.dart';
import '../storage/database.dart';
import '../storage/repo.dart';
import 'bridge_connection.dart';
import 'codec.dart';
import '../nomadnet/browser_sync.dart';
import 'vault_store.dart';

/// This device has no vault key (e.g. it was paired by an older app), so it
/// cannot hand the key on to another device.
class VaultKeyMissing implements Exception {
  @override
  String toString() => 'this device has no vault key';
}

enum VaultState {
  /// Bridge mode is off or the bridge is not connected.
  off,

  /// The vault is in use but nobody wrapped its key for this device.
  needsKey,
  syncing,
  idle,

  /// The bridge refused uploads: the per-device quota is full.
  quotaFull,
  error,
}

class VaultStatus {
  const VaultStatus({
    required this.state,
    this.lastSync,
    this.usedBytes = 0,
    this.quotaBytes = 0,
    this.remoteDevices = 0,
    this.skippedBlobs = 0,
    this.uploadedBlobs = 0,
    this.downloaded = const {},
    this.lastError,
    this.browserSent = 0,
    this.browserReceived = 0,
  });

  /// Browser data records (bookmarks, favourites, settings, history visits)
  /// uploaded by this device / merged from other devices.
  final int browserSent;
  final int browserReceived;

  final VaultState state;
  final DateTime? lastSync;
  final int usedBytes;
  final int quotaBytes;
  final int remoteDevices;

  /// Blobs of this session that failed to decrypt or verify and were skipped.
  final int skippedBlobs;

  /// Blobs this device has uploaded (its upload sequence number).
  final int uploadedBlobs;

  /// Blobs downloaded per other device id (the last `seq` read).
  final Map<String, int> downloaded;

  /// The last failure of a sync pass (cleared by the next good pass).
  final String? lastError;
}

/// The group-key chain and the invite secret, kept in the secure store and
/// tied to one bridge (address + `state_id`): a different bridge means a
/// different vault.
class VaultKeys {
  VaultKeys(this.secrets);
  final SecretStore secrets;

  static const _key = 'kestrel.vault.keys.v1';

  String? bridge;
  String? stateId;
  Map<int, Uint8List> chain = {};
  Uint8List? inviteSecret;
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final raw = await secrets.read(_key);
    if (raw == null || raw.isEmpty) return;
    try {
      final m = json.decode(raw) as Map<String, Object?>;
      bridge = m['bridge'] as String?;
      stateId = m['state_id'] as String?;
      final c = m['chain'] as String?;
      if (c != null && c.isNotEmpty) {
        chain = VaultCrypto.unpackChain(base64.decode(c));
      }
      final inv = m['invite'] as String?;
      if (inv != null && inv.isNotEmpty) inviteSecret = base64.decode(inv);
    } on Object {
      chain = {};
    }
  }

  Future<void> save() => secrets.write(
    _key,
    json.encode({
      'bridge': bridge,
      'state_id': stateId,
      'chain': chain.isEmpty ? '' : base64.encode(VaultCrypto.packChain(chain)),
      'invite': inviteSecret == null ? '' : base64.encode(inviteSecret!),
    }),
  );

  Future<void> clear({bool keepBinding = true}) async {
    chain = {};
    inviteSecret = null;
    if (!keepBinding) {
      bridge = null;
      stateId = null;
    }
    await save();
  }
}

/// What `/vault/key` said.
class _KeyInfo {
  _KeyInfo(Map<String, Object?> m)
    : epoch = asInt(m['key_epoch']) ?? 1,
      inUse = m['in_use'] == true,
      wrap = m['wrap'] as String?,
      wrapped = m['wrapped_group_key'] is Uint8List
          ? m['wrapped_group_key']! as Uint8List
          : null;
  final int epoch;
  final bool inUse;
  final String? wrap;
  final Uint8List? wrapped;
}

/// E2E-encrypted sync of this device's Standalone (B) history through the
/// bridge vault (docs/bridge-protocol.md section 9): key management, the
/// uploader and the downloader. The bridge only ever sees ciphertext.
class VaultService {
  VaultService({
    required this.repo,
    required this.keys,
    required this.identity,
    required this.ownDeviceId,
    this.debounce = const Duration(seconds: 2),
    this.gapRetry = const Duration(seconds: 30),
    this.pollEvery = const Duration(minutes: 5),
    this.errorRetry = const Duration(seconds: 60),
    Duration historyBatch = const Duration(minutes: 3),
  }) : store = VaultStore(repo) {
    store.historyBatchMs = historyBatch.inMilliseconds;
  }

  final Repo repo;
  final VaultStore store;
  final VaultKeys keys;
  final Identity Function() identity;
  final String Function() ownDeviceId;
  final Duration debounce;
  final Duration gapRetry;
  final Duration pollEvery;
  final Duration errorRetry;

  /// Cancels queued B messages in the LXMF router (by hash) before another
  /// device's `delete_chat` removes them here; wired by `NodeService`.
  Future<void> Function(List<String> lxmfHashes)? cancelOutbound;

  /// This device may delete a read-only chat of another device: the vault is
  /// connected and holds the key (the deletion travels as a vault blob).
  bool get canDeleteRemote => _api != null && keys.chain.isNotEmpty;

  BridgeApi? _api;
  HelloResult? _hello;
  VaultState _state = VaultState.off;
  int _epoch = 1;
  int _skipped = 0;
  int _blobShrink = 1;
  bool _busy = false;
  bool _again = false;
  bool _noKeySkips = false;
  Timer? _debounce;
  Timer? _retry;
  Timer? _poll;
  Timer? _historyTimer;
  String? _lastError;
  StreamSubscription<void>? _dbSub;
  final List<DateTime> _putTimes = [];
  Future<void> _running = Future.value();

  VaultState get state => _state;
  int get currentEpoch => _epoch;

  void _setState(VaultState s) {
    if (s == _state) return;
    _state = s;
    repo.adb.notify();
  }

  // --------------------------------------------------------------- lifecycle

  /// A bridge connection was created for [bridgeKeyHex].
  Future<void> attach(BridgeApi api, String bridgeKeyHex) async {
    await detach();
    _api = api;
    await keys.load();
    if (keys.bridge != null && keys.bridge != bridgeKeyHex) {
      // another bridge: its vault has nothing to do with the old one
      await keys.clear(keepBinding: false);
      await store.resetForNewBridge();
    }
    keys.bridge = bridgeKeyHex;
    await keys.save();
    _dbSub = repo.adb.changes.listen((_) => _onDbChange());
  }

  /// Connection gone or bridge mode off: stops everything (keys stay).
  Future<void> detach() async {
    _debounce?.cancel();
    _retry?.cancel();
    _poll?.cancel();
    _historyTimer?.cancel();
    await _dbSub?.cancel();
    _dbSub = null;
    _api = null;
    _hello = null;
    _setState(VaultState.off);
  }

  /// Drops the key chain and invite secret (this device was revoked).
  Future<void> forgetKeys() async {
    await keys.load();
    await keys.clear(keepBinding: false);
  }

  /// The invite this (new) device is about to redeem carries the secret that
  /// opens the key chain the inviter wrapped for it.
  Future<void> rememberInviteSecret(Uint8List? secret) async {
    await keys.load();
    keys.inviteSecret = secret;
    await keys.save();
  }

  /// Waits until a running pass has finished (tests).
  Future<void> whenIdle() async {
    await _running;
  }

  // ----------------------------------------------------------------- triggers

  /// `/hello` + `/subscribe` done: reconcile keys, download, upload.
  Future<void> onConnected(HelloResult h) {
    _hello = h;
    _epoch = h.vaultKeyEpoch;
    // a safety net for a missed `vault.blob` push: look again from time to time
    _poll?.cancel();
    _poll = Timer.periodic(pollEvery, (_) => unawaited(_schedule()));
    return _schedule(immediate: true);
  }

  /// "Sync now": a full pass (keys, download, upload), also after an error.
  Future<void> syncNow() {
    _retry?.cancel();
    return _schedule(immediate: true);
  }

  /// `vault.blob` push: somebody uploaded.
  Future<void> onBlobPush() => _schedule(immediate: true);

  /// Upload the browsing history now (the app goes to the background)
  /// instead of waiting for the batch interval.
  Future<void> flushHistory() async {
    store.flushHistory = true;
    await _schedule(immediate: true);
  }

  /// A timer for history visits that are waiting for their batch to be due.
  Future<void> _armHistoryTimer() async {
    _historyTimer?.cancel();
    try {
      final oldest = await store.browser.oldestUnsyncedHistory();
      if (oldest == null || _api == null) return;
      final due = oldest + store.historyBatchMs;
      final wait = due - DateTime.now().millisecondsSinceEpoch;
      _historyTimer = Timer(
        Duration(milliseconds: (wait < 0 ? 0 : wait) + 250),
        () => unawaited(_schedule()),
      );
    } on Object {
      // database closed
    }
  }

  /// Keys may have been rotated (`device_revoked` push, epoch change).
  Future<void> onKeysMayHaveChanged() => _schedule(immediate: true);

  void _onDbChange() {
    if (_busy || _hello == null) return;
    _debounce?.cancel();
    _debounce = Timer(debounce, () async {
      try {
        if (await store.hasUploadWork()) {
          unawaited(_schedule());
        } else {
          unawaited(_armHistoryTimer());
        }
      } on Object {
        // database closed
      }
    });
  }

  Future<void> _schedule({bool immediate = false}) {
    if (_api == null || _hello == null) return Future.value();
    if (_busy) {
      _again = true;
      return _running;
    }
    _busy = true;
    _running = _runPasses();
    return _running;
  }

  Future<void> _runPasses() async {
    try {
      var rounds = 0;
      do {
        _again = false;
        await _pass();
        // messages that arrived while the pass ran: the database change that
        // announced them was ignored because the pass was busy
        if (!_again &&
            _api != null &&
            _state == VaultState.idle &&
            rounds < 20 &&
            await _hasUploadWorkSafe()) {
          _again = true;
        }
        rounds++;
      } while (_again && _api != null);
    } finally {
      _busy = false;
    }
  }

  Future<bool> _hasUploadWorkSafe() async {
    try {
      return await store.hasUploadWork();
    } on Object {
      return false; // database closed (shutdown)
    }
  }

  void _fail(String what) {
    _lastError = what;
    unawaited(repo.setSetting(SettingKeys.vaultLastError, what));
    _scheduleRetry(errorRetry.inSeconds.toDouble());
  }

  Future<void> _pass() async {
    final api = _api;
    final h = _hello;
    if (api == null || h == null) return;
    _setState(VaultState.syncing);
    _lastError = null;
    try {
      await noteHello(h);
      if (!await _ensureKeys()) {
        _setState(VaultState.needsKey);
        return;
      }
      // before anything is downloaded: an existing local item must have its
      // record, or an older remote tombstone could delete it
      await store.browser.backfillOnce(repo.getSetting, repo.setSetting);
      try {
        await _download(api, h);
      } on BridgeError catch (e) {
        // a failed download must not keep this device's own history from
        // being uploaded
        if (e.code == 'device_revoked') rethrow;
        _fail('download: ${e.code}');
        debugPrint('vault download: ${e.code}');
      } on BridgeTransportError {
        rethrow;
      } on Object catch (e) {
        if (_api == null) return;
        _fail('download: $e');
        debugPrint('vault download failed: $e');
      }
      final stop = await _upload(api, h);
      if (stop == VaultState.quotaFull) {
        _setState(VaultState.quotaFull);
      } else if (stop == VaultState.error) {
        _setState(VaultState.error);
      } else {
        _setState(_lastError == null ? VaultState.idle : VaultState.error);
        if (_lastError == null) {
          await repo.setSetting(SettingKeys.vaultLastError, '');
        }
      }
      if (_lastError == null) await store.touchLastSync(DateTime.now());
      store.flushHistory = false;
      await _armHistoryTimer();
    } on BridgeTransportError {
      _setState(VaultState.off);
    } on BridgeError catch (e) {
      debugPrint('vault sync: ${e.code}');
      _setState(e.code == 'device_revoked' ? VaultState.off : VaultState.error);
      if (e.code != 'device_revoked') _fail(e.code);
    } on Object catch (e, st) {
      if (_api == null) return; // detached meanwhile (bridge off, stop)
      debugPrint('vault sync failed: $e\n$st');
      _setState(VaultState.error);
      _fail('$e');
    }
  }

  // ------------------------------------------------------------ key handling

  Future<_KeyInfo> _keyInfo() async =>
      _KeyInfo(await _api!.call('/vault/key', {}));

  /// Makes sure the chain holds the key of the current epoch: activates the
  /// vault when nobody has, or unwraps what another device wrapped for us.
  Future<bool> _ensureKeys() async {
    await keys.load();
    final h = _hello;
    if (h == null) return false;
    if (keys.stateId != null && keys.stateId != h.stateId) {
      // the bridge database was recreated: no key and no upload state is valid
      await keys.clear();
      await store.resetForNewBridge();
    }
    if (keys.stateId != h.stateId) {
      keys.stateId = h.stateId;
      await keys.save();
    }
    final info = await _keyInfo();
    _epoch = info.epoch;
    if (!info.inUse) {
      if (keys.chain.isNotEmpty) await keys.clear();
      return _activate(info.epoch);
    }
    if (keys.chain.containsKey(info.epoch)) return true;
    return _adopt(info);
  }

  /// Unwraps the key the bridge holds for us and merges it into the chain.
  Future<bool> _adopt(_KeyInfo info) async {
    Map<int, Uint8List>? got;
    final w = info.wrapped;
    if (w != null) {
      if (info.wrap == 'invite') {
        final secret = keys.inviteSecret;
        if (secret != null) got = await VaultCrypto.unwrapFromInvite(w, secret);
      } else {
        got = await VaultCrypto.unwrapFromIdentity(w, identity());
      }
    }
    if (got == null) return false;
    await _merge(got);
    return keys.chain.containsKey(info.epoch);
  }

  Future<void> _merge(Map<int, Uint8List> more) async {
    final before = keys.chain.length;
    keys.chain = {...keys.chain, ...more};
    await keys.save();
    if (keys.chain.length > before && _noKeySkips) {
      // blobs were skipped for lack of a key: read them again
      _noKeySkips = false;
      await store.rewind();
    }
  }

  /// Nobody has activated the vault: generate the first group key and wrap it
  /// for every trusted device. Loses gracefully against a concurrent device.
  Future<bool> _activate(int epoch) async {
    final api = _api!;
    var ep = epoch;
    for (var attempt = 0; attempt < 3; attempt++) {
      final r = await api.call('/devices/list', {'include_revoked': false});
      final devices = [
        for (final m in asMapList(r['devices'])) DeviceRecord.fromMap(m),
      ].where((d) => !d.isRevoked && d.publicKey.length == 128).toList();
      final chain = {ep: VaultCrypto.generateGroupKey()};
      final wrapped = <String, Uint8List>{
        for (final d in devices)
          d.deviceId: await VaultCrypto.wrapToIdentity(
            chain,
            Identity.fromPublicKey(fromHex(d.publicKey)),
          ),
      };
      try {
        await api.call('/vault/set_keys', {
          'key_epoch': ep,
          'wrapped_group_keys': wrapped,
        });
        await _merge(chain);
        return true;
      } on BridgeError catch (e) {
        if (e.code == 'keys_already_set') {
          final info = await _keyInfo();
          _epoch = info.epoch;
          return keys.chain.containsKey(info.epoch) || await _adopt(info);
        }
        if (e.code == 'key_epoch_stale') {
          ep = asInt(e.details['key_epoch']) ?? ep;
          continue;
        }
        if (e.code == 'bad_request' && e.details.containsKey('missing')) {
          continue; // the device list changed meanwhile
        }
        rethrow;
      }
    }
    return false;
  }

  // ---- fields for the device administration calls (spec 9.3 / 5.4) ----------

  /// `key_epoch` + `wrapped_group_key` for `/devices/approve` while the vault
  /// is in use, `{}` otherwise. Throws [VaultKeyMissing] without a key.
  Future<Map<String, Object?>> approveFields(
    List<int> newDevicePublicKey,
  ) async {
    await keys.load();
    final info = await _keyInfo();
    _epoch = info.epoch;
    if (!info.inUse) return {};
    if (!keys.chain.containsKey(info.epoch)) throw VaultKeyMissing();
    return {
      'key_epoch': info.epoch,
      'wrapped_group_key': await VaultCrypto.wrapToIdentity(
        keys.chain,
        Identity.fromPublicKey(newDevicePublicKey),
      ),
    };
  }

  /// Fields for `/devices/invite`: while the vault is in use the chain wrapped
  /// to a fresh invite secret (which goes only into the QR code).
  Future<({Map<String, Object?> args, Uint8List? secret})>
  inviteFields() async {
    await keys.load();
    final info = await _keyInfo();
    _epoch = info.epoch;
    if (!info.inUse) return (args: <String, Object?>{}, secret: null);
    if (!keys.chain.containsKey(info.epoch)) throw VaultKeyMissing();
    final secret = secureRandomBytes(32);
    return (
      args: <String, Object?>{
        'key_epoch': info.epoch,
        'wrapped_group_key': await VaultCrypto.wrapToInvite(keys.chain, secret),
      },
      secret: secret,
    );
  }

  /// Fields for `/devices/revoke` of [targetId]: a new random group key for
  /// epoch + 1, wrapped (with all older epochs this device knows) for every
  /// remaining trusted device. [commit] stores the new chain after the bridge
  /// accepted the revocation.
  Future<({Map<String, Object?> args, Future<void> Function() commit})>
  revokeFields(String targetId) async {
    await keys.load();
    final info = await _keyInfo();
    _epoch = info.epoch;
    if (!info.inUse) {
      return (args: <String, Object?>{}, commit: () async {});
    }
    final next = info.epoch + 1;
    final newChain = {...keys.chain, next: VaultCrypto.generateGroupKey()};
    final r = await _api!.call('/devices/list', {'include_revoked': false});
    final remaining = [
      for (final m in asMapList(r['devices'])) DeviceRecord.fromMap(m),
    ].where((d) => !d.isRevoked && d.deviceId != targetId).toList();
    final wrapped = <String, Uint8List>{
      for (final d in remaining)
        d.deviceId: await VaultCrypto.wrapToIdentity(
          newChain,
          Identity.fromPublicKey(fromHex(d.publicKey)),
        ),
    };
    return (
      args: <String, Object?>{'key_epoch': next, 'wrapped_group_keys': wrapped},
      commit: () async {
        await _merge(newChain);
        _epoch = next;
        unawaited(_schedule(immediate: true));
      },
    );
  }

  // ---------------------------------------------------------------- uploading

  /// One record of a message (spec 9.5).
  Map<String, Object?> _record(UploadCandidate c, {String? text}) => {
    'hash': c.lxmfHash,
    'peer': c.peer,
    'peer_name': c.peerName,
    'incoming': c.incoming,
    'title': c.title ?? '',
    'text': text ?? c.text,
    if (text != null) 'text_truncated': true,
    'ts': c.tsMs / 1000,
    'rts': DateTime.now().millisecondsSinceEpoch / 1000,
    'state': c.status,
    'method': c.route,
    'transport': c.transport,
    'error': c.error,
  };

  /// Builds the next blob from pending messages, stores it (before any
  /// upload) and returns it; null when there is nothing to upload.
  Future<PendingBlob?> _build(HelloResult h) async {
    final gk = keys.chain[_epoch];
    if (gk == null) return null;
    final del = await store.nextDelete();
    if (del != null) return _buildDelete(gk, del);
    final browser = await _buildBrowser(h, gk);
    if (browser != null) return browser;
    final cands = await store.candidates(300);
    if (cands.isEmpty) return null;
    final maxBlob = h.limit('vault_max_blob_bytes', 131072) ~/ _blobShrink;
    // token overhead (48) + padding (16) + metadata (~200) + slack
    final budget = maxBlob - 512;
    if (budget < 256) return null;

    final records = <Map<String, Object?>>[];
    final used = <UploadCandidate>[];
    var size = 0;
    for (final c in cands) {
      var rec = _record(c);
      var n = packb(rec).length + 4;
      if (n > budget) {
        // a single huge message: keep the start of its text
        var cut = c.text.runes.length;
        while (n > budget && cut > 16) {
          cut = cut ~/ 2;
          rec = _record(c, text: String.fromCharCodes(c.text.runes.take(cut)));
          n = packb(rec).length + 4;
        }
        if (n > budget) {
          rec = _record(c, text: '');
          n = packb(rec).length + 4;
        }
      }
      if (used.isNotEmpty && size + n > budget) break;
      records.add(rec);
      used.add(c);
      size += n;
    }

    final seq = (await store.lastSeq()) + 1;
    final blobId = toHex(secureRandomBytes(16));
    Uint8List ct;
    while (true) {
      ct = await VaultCrypto.encryptBlob(
        groupKey: gk,
        blobId: blobId,
        deviceId: ownDeviceId(),
        seq: seq,
        keyEpoch: _epoch,
        kind: 'messages',
        ts: DateTime.now().millisecondsSinceEpoch / 1000,
        data: {'records': records},
      );
      if (ct.length <= maxBlob || records.length <= 1) break;
      final keep = records.length ~/ 2;
      records.removeRange(keep, records.length);
      used.removeRange(keep, used.length);
    }
    final p = PendingBlob(
      blobId: blobId,
      seq: seq,
      keyEpoch: _epoch,
      ciphertext: ct,
      marks: [
        for (final c in used) [c.messageId, c.status, c.error, c.lxmfHash],
      ],
    );
    await store.savePending(p);
    return p;
  }

  /// The blob of a deleted B chat (kind `delete_chat`, spec 9.6): the other
  /// devices remove their read-only copy of the messages up to `before_ts`.
  /// One `browser` blob (docs/bridge-protocol.md 9.5): as many waiting
  /// records as fit under the blob size limit.
  Future<PendingBlob?> _buildBrowser(HelloResult h, Uint8List gk) async {
    final waiting = await store.browserOps(400);
    if (waiting.isEmpty) return null;
    final maxBlob = h.limit('vault_max_blob_bytes', 131072) ~/ _blobShrink;
    final budget = maxBlob - 512;
    if (budget < 256) return null;
    final used = <PendingOp>[];
    var size = 0;
    for (final w in waiting) {
      final n = packb(w.op).length + 4;
      if (used.isNotEmpty && size + n > budget) break;
      used.add(w);
      size += n;
    }
    final seq = (await store.lastSeq()) + 1;
    final blobId = toHex(secureRandomBytes(16));
    Uint8List ct;
    while (true) {
      ct = await VaultCrypto.encryptBlob(
        groupKey: gk,
        blobId: blobId,
        deviceId: ownDeviceId(),
        seq: seq,
        keyEpoch: _epoch,
        kind: browserBlobKind,
        ts: DateTime.now().millisecondsSinceEpoch / 1000,
        data: {
          'ops': [for (final u in used) u.op],
        },
      );
      if (ct.length <= maxBlob || used.length <= 1) break;
      used.removeRange(used.length ~/ 2, used.length);
    }
    final p = PendingBlob(
      blobId: blobId,
      seq: seq,
      keyEpoch: _epoch,
      ciphertext: ct,
      marks: [for (final u in used) u.mark],
    );
    await store.savePending(p);
    return p;
  }

  Future<PendingBlob> _buildDelete(
    Uint8List gk,
    ({int id, String peer, String? owner, int beforeTsMs}) del,
  ) async {
    final seq = (await store.lastSeq()) + 1;
    final blobId = toHex(secureRandomBytes(16));
    final ct = await VaultCrypto.encryptBlob(
      groupKey: gk,
      blobId: blobId,
      deviceId: ownDeviceId(),
      seq: seq,
      keyEpoch: _epoch,
      kind: 'delete_chat',
      ts: DateTime.now().millisecondsSinceEpoch / 1000,
      data: {
        'peer': del.peer,
        'owner_device': ?del.owner,
        'before_ts': del.beforeTsMs / 1000,
      },
    );
    final p = PendingBlob(
      blobId: blobId,
      seq: seq,
      keyEpoch: _epoch,
      ciphertext: ct,
      marks: [
        [deleteMark, del.id],
      ],
    );
    await store.savePending(p);
    return p;
  }

  /// Uploads until nothing is left. Returns [VaultState.quotaFull] /
  /// [VaultState.error] when it had to stop for that reason, else idle.
  Future<VaultState> _upload(BridgeApi api, HelloResult h) async {
    final rate = h.limit('vault_put_rate_per_minute', 120);
    var guard = 0;
    while (guard++ < 10000) {
      var p = await store.pending();
      p ??= await _build(h);
      if (p == null) {
        await store.saveUsage(full: false);
        return VaultState.idle;
      }
      // stay below the per-minute put limit
      final now = DateTime.now();
      _putTimes.removeWhere((t) => now.difference(t).inSeconds >= 60);
      if (_putTimes.length >= rate - 5) {
        _scheduleRetry(60 - now.difference(_putTimes.first).inSeconds + 1.0);
        return VaultState.idle;
      }
      try {
        final r = await api.call('/vault/put', {
          'blob_id': p.blobId,
          'device_id': ownDeviceId(),
          'seq': p.seq,
          'key_epoch': p.keyEpoch,
          'ciphertext': p.ciphertext,
        });
        _putTimes.add(DateTime.now());
        await store.completePending(p);
        if (r['duplicate'] != true) {
          await store.saveUsage(
            used: (await store.usedBytes()) + p.ciphertext.length,
          );
        }
      } on BridgeError catch (e) {
        switch (e.code) {
          case 'key_epoch_stale':
            // a revocation rotated the key: re-encrypt the same messages
            await store.clearPending();
            _epoch = asInt(e.details['key_epoch']) ?? _epoch + 1;
            if (!await _ensureKeys()) return VaultState.error;
          case 'seq_conflict':
            await store.clearPending();
            await store.saveLastSeq(asInt(e.details['last_seq']) ?? 0);
          case 'blob_conflict':
            await store.clearPending();
          case 'blob_too_large':
            await store.clearPending();
            if (_blobShrink >= 16) return VaultState.error;
            _blobShrink *= 2;
          case 'quota_exceeded':
            await store.saveUsage(
              used: asInt(e.details['used']),
              quota: asInt(e.details['quota']),
              full: true,
            );
            return VaultState.quotaFull;
          case 'rate_limited':
            _scheduleRetry(e.retryAfter ?? 30);
            return VaultState.idle;
          default:
            debugPrint('vault put refused: ${e.code}');
            _fail('upload: ${e.code}');
            return VaultState.error;
        }
      }
    }
    return VaultState.idle;
  }

  void _scheduleRetry(double seconds) {
    _retry?.cancel();
    _retry = Timer(
      Duration(milliseconds: (seconds * 1000).ceil() + 250),
      () => unawaited(_schedule()),
    );
  }

  // -------------------------------------------------------------- downloading

  Future<void> _download(BridgeApi api, HelloResult h) async {
    final own = ownDeviceId();
    final maxIds = h.limit('vault_get_max_ids', 32);
    var cursor = await store.cursor();
    var refreshedKeys = false;
    // First blob a device is missing: the saved cursor never moves past it,
    // so the next pass reads it again; blobs of OTHER devices behind it are
    // still applied (a gap in one device's sequence blocks only that device).
    int? holdAt;
    final gapped = <String>{};
    while (true) {
      final r = await api.call('/vault/list', {'cursor': cursor, 'limit': 100});
      final metas = [for (final m in asMapList(r['blobs'])) ?_Meta.tryParse(m)];
      if (metas.isEmpty) break;
      for (var i = 0; i < metas.length; i += maxIds) {
        final chunk = metas.sublist(
          i,
          i + maxIds > metas.length ? metas.length : i + maxIds,
        );
        final wanted = [
          for (final m in chunk)
            if (m.deviceId != own &&
                !gapped.contains(m.deviceId) &&
                m.seq > await store.seen(m.deviceId))
              m.blobId,
        ];
        final got = await _fetch(api, wanted);
        for (final m in chunk) {
          if (m.deviceId == own) continue;
          final seen = await store.seen(m.deviceId);
          if (m.seq <= seen) continue;
          if (gapped.contains(m.deviceId)) continue;
          if (m.seq > seen + 1) {
            // a blob of this device is not uploaded (yet): try again later
            debugPrint('vault: gap for a device (have $seen, got ${m.seq})');
            gapped.add(m.deviceId);
            holdAt ??= m.vcursor - 1;
            continue;
          }
          final ct = got[m.blobId];
          if (ct == null) {
            _skipped++;
            debugPrint('vault: blob missing or too large, skipped');
          } else {
            if (!keys.chain.containsKey(m.keyEpoch) && !refreshedKeys) {
              refreshedKeys = true;
              try {
                final info = await _keyInfo();
                if (info.inUse) await _adopt(info);
              } on BridgeError {
                // handled below as a missing key
              }
            }
            if (!keys.chain.containsKey(m.keyEpoch)) _noKeySkips = true;
            await _applyBlob(m, ct);
          }
          await store.setSeen(m.deviceId, m.seq);
        }
        cursor = chunk.last.vcursor;
        await store.saveCursor(
          holdAt == null || cursor < holdAt ? cursor : holdAt,
        );
      }
      if (r['more'] != true) break;
    }
    if (holdAt != null) {
      _retry?.cancel();
      _retry = Timer(gapRetry, () => unawaited(_schedule()));
    }
  }

  Future<void> _applyBlob(_Meta m, Uint8List ct) async {
    try {
      final plain = await VaultCrypto.decryptBlob(
        ciphertext: ct,
        chain: keys.chain,
        blobId: m.blobId,
        deviceId: m.deviceId,
        seq: m.seq,
        keyEpoch: m.keyEpoch,
      );
      final data = plain.data;
      switch (plain.kind) {
        case 'messages':
          final records = data is Map ? data['records'] : null;
          if (records is List) await store.applyRecords(m.deviceId, records);
        case browserBlobKind:
          final ops = data is Map ? data['ops'] : null;
          if (ops is List) await store.applyBrowser(ops);
        case 'delete_chat':
          // the uploading device deleted that chat: drop its read-only copy
          final peer = data is Map ? data['peer'] : null;
          final before = data is Map ? data['before_ts'] : null;
          final owner = data is Map && data['owner_device'] is String
              ? data['owner_device']! as String
              : m.deviceId;
          if (peer is String &&
              peer.isNotEmpty &&
              peer.length <= 64 &&
              before is num &&
              owner.length <= 64) {
            final ms = (before * 1000).ceil();
            if (owner == ownDeviceId()) {
              // another device deleted OUR chat: it goes here too
              await cancelOutbound?.call(await repo.unsentHashes(peer, ms));
              await repo.deleteOwnChatBefore(owner, peer, ms);
            } else {
              await repo.removeVaultHistory(owner, peer, beforeTsMs: ms);
            }
          }
        default:
          return; // a kind from a newer app
      }
    } on VaultCryptoException catch (e) {
      _skipped++;
      debugPrint('vault: blob skipped (${e.message})');
    } on Object catch (e) {
      // a malformed blob of another device (unexpected types, ...) is
      // skipped like an undecryptable one: it must not stall the sync of
      // every later blob, nor this device's own uploads
      if (_api == null) rethrow;
      _skipped++;
      debugPrint('vault: blob skipped (malformed: $e)');
    }
  }

  /// `/vault/get` for [ids] in groups the response limit allows; a blob that
  /// never fits is left out (the caller skips it).
  Future<Map<String, Uint8List>> _fetch(BridgeApi api, List<String> ids) async {
    final out = <String, Uint8List>{};
    final queue = <List<String>>[ids];
    while (queue.isNotEmpty) {
      final group = queue.removeAt(0);
      if (group.isEmpty) continue;
      final r = await api.call('/vault/get', {'blob_ids': group});
      for (final b in asMapList(r['blobs'])) {
        final id = b['blob_id'];
        final ct = b['ciphertext'];
        if (id is String && ct is Uint8List) out[id] = ct;
      }
      final truncated = [
        if (r['truncated'] is List)
          for (final x in r['truncated']! as List)
            if (x is String) x,
      ];
      // a blob that does not fit even alone is left out: the caller skips it
      if (truncated.isEmpty || group.length == 1) continue;
      final half = (truncated.length + 1) ~/ 2;
      queue.insertAll(0, [
        truncated.sublist(0, half),
        if (truncated.length > half) truncated.sublist(half),
      ]);
    }
    return out;
  }

  // ------------------------------------------------------------------ status

  Future<VaultStatus> snapshot() async => VaultStatus(
    state: _state,
    lastSync: await store.lastSync(),
    usedBytes: await store.usedBytes(),
    quotaBytes: await store.quotaBytes(),
    remoteDevices: await store.remoteDeviceCount(),
    skippedBlobs: _skipped,
    uploadedBlobs: await store.lastSeq(),
    downloaded: await store.seenAll(),
    lastError: _lastError ?? await store.lastError(),
    browserSent: (await store.browserCounts()).$1,
    browserReceived: (await store.browserCounts()).$2,
  );

  /// Refreshes the stored usage numbers from `/hello`.
  Future<void> noteHello(HelloResult h) async {
    await store.saveUsage(
      used: h.vaultUsedBytes,
      quota: h.limit('vault_device_quota_bytes', 0),
    );
  }
}

class _Meta {
  _Meta(this.vcursor, this.blobId, this.deviceId, this.seq, this.keyEpoch);

  static _Meta? tryParse(Map<String, Object?> m) {
    final v = asInt(m['vcursor']);
    final seq = asInt(m['seq']);
    final ep = asInt(m['key_epoch']);
    final b = m['blob_id'];
    final d = m['device_id'];
    if (v == null ||
        seq == null ||
        ep == null ||
        b is! String ||
        d is! String) {
      return null;
    }
    return _Meta(v, b, d, seq, ep);
  }

  final int vcursor;
  final String blobId;
  final String deviceId;
  final int seq;
  final int keyEpoch;
}
