import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../crypto/hashes.dart';
import '../crypto/random.dart';
import '../destination.dart';
import '../identity.dart';
import '../lxmf/lx_message.dart';
import '../lxmf/lxm_router.dart';
import '../msgpack/msgpack.dart';
import '../reticulum.dart';
import '../storage.dart';
import '../util.dart';
import '../vault_crypto.dart';
import 'group_models.dart';
import 'group_state.dart';

/// Version of the device sync protocol (docs/device-sync.md).
const int kDeviceSyncVersion = 1;

/// LXMF field keys carrying a sync message (FIELD_CUSTOM_TYPE / DATA).
const int syncFieldType = 0xFB;
const int syncFieldData = 0xFC;
const String syncTypeRecord = 'kestrel.sync.v1';
const String syncTypeGap = 'kestrel.sync.gap.v1';

/// Record kinds with built-in handling; the app adds its own (`messages`,
/// `delete_chat`, `browser`, `read`, ...).
abstract final class SyncKind {
  static const devices = 'devices';
  static const name = 'name';
  static const ratchets = 'ratchets';
  static const rekey = 'rekey';
  static const identity = 'identity';
  static const messages = 'messages';
  static const deleteChat = 'delete_chat';
  static const browser = 'browser';
  static const read = 'read';
  static const backfillRequest = 'backfill_req';
  static const backfill = 'backfill';
}

/// One applied sync record (decrypted, in per-device `seq` order).
class SyncRecord {
  SyncRecord({
    required this.origin,
    required this.seq,
    required this.kind,
    required this.ts,
    required this.data,
  });

  /// Device id (hex) that produced the record.
  final String origin;

  /// Per-origin sequence number; 0 = targeted record outside the sequence.
  final int seq;
  final String kind;
  final double ts;
  final Object? data;
}

/// An additional carrier of the same envelopes (the bridge vault when the
/// MeshChatX add-on is on). Received envelopes are fed to
/// [DeviceSync.ingest]; dedupe is by `(origin, seq)`, so the same record
/// arriving over several transports is applied once.
abstract class SyncTransport {
  /// Hands [envelope] over for delivery ([to] = target device ids, null = all).
  Future<void> send(Map<String, Object?> envelope, {Iterable<String>? to});
}

/// Durable bookkeeping of the sync: own sequence, the last applied sequence
/// per device and the log of own records (answers gap requests).
abstract class SyncStore {
  Future<int> ownSeq();
  Future<void> saveOwnSeq(int seq);
  Future<int> seen(String device);
  Future<void> setSeen(String device, int seq);
  Future<void> saveRecord(int seq, Uint8List packed);
  Future<Uint8List?> record(int seq);
  Future<void> pruneRecords(int belowSeq);
}

/// [SyncStore] on a [KestrelStorage] (JSON files / memory).
class KestrelSyncStore implements SyncStore {
  KestrelSyncStore(this._s, {this.keep = 1000});
  final KestrelStorage _s;
  final int keep;

  @override
  Future<int> ownSeq() async =>
      ((await _s.read('sync/own'))?['seq'] as int?) ?? 0;

  @override
  Future<void> saveOwnSeq(int seq) => _s.write('sync/own', {'seq': seq});

  @override
  Future<int> seen(String device) async =>
      ((await _s.read('sync/seen/$device'))?['seq'] as int?) ?? 0;

  @override
  Future<void> setSeen(String device, int seq) =>
      _s.write('sync/seen/$device', {'seq': seq});

  @override
  Future<void> saveRecord(int seq, Uint8List packed) =>
      _s.write('sync/log/$seq', {'r': base64.encode(packed)});

  @override
  Future<Uint8List?> record(int seq) async {
    final r = (await _s.read('sync/log/$seq'))?['r'];
    return r is String ? base64.decode(r) : null;
  }

  @override
  Future<void> pruneRecords(int belowSeq) async {
    final from = belowSeq - 50 > 1 ? belowSeq - 50 : 1;
    for (var i = from; i < belowSeq; i++) {
      await _s.delete('sync/log/$i');
    }
  }
}

/// Sync of the records between the devices of a group, over LXMF between
/// the hidden device keys.
///
///  * Every record is encrypted with `VaultCrypto.encryptBlob` and decrypted
///    only through `VaultCrypto.decryptBlob` (inner `blob_id`, `device_id`,
///    `seq`, `key_epoch` must match the outer envelope).
///  * One LXMF message per sibling device (a propagation node deletes a
///    message after the first download, so each device needs its own copy);
///    the router delivers directly when the sibling is online and falls back
///    to the propagation node otherwise.
///  * Per-origin `seq` continuity: duplicates are ignored, out-of-order
///    records wait, a gap triggers a gap request answered from the origin's
///    log. The same envelope also travels through the bridge vault: feed it to
///    [ingest] and dedupe is by `(origin, seq)`.
class DeviceSync {
  DeviceSync({
    required this.rns,
    required this.router,
    required this.deviceKey,
    required this.state,
    required this.store,
    this.group,
    this.onStateChanged,
    this.onIdentity,
    this.gapDelay = const Duration(seconds: 3),
    RandomBytes? random,
  }) : _random = random ?? secureRandomBytes;

  final Reticulum rns;

  /// LXMF router of the device key (not the group identity).
  final LxmRouter router;
  final Identity deviceKey;
  final GroupState state;
  final SyncStore store;

  /// The group identity's destination (ratchet records merge into it). Set to
  /// the new destination after an `identity` record switched the router.
  Destination? group;

  /// Called after an `identity` record from a sibling was adopted (it is newer
  /// than the current identity, [state] already carries its generation and was
  /// persisted via [onStateChanged]). The app switches its router/announcer to
  /// the new G here and retires the old one. Not called for the device that
  /// published the change.
  final Future<void> Function(IdentityChange change)? onIdentity;

  /// Called after built-in records changed [state] (persist it).
  final void Function()? onStateChanged;
  final Duration gapDelay;
  final RandomBytes _random;

  /// Carriers besides LXMF between the device keys.
  final List<SyncTransport> extraTransports = [];

  String get ownId => toHex(deviceKey.hash);

  final _records = StreamController<SyncRecord>.broadcast();
  StreamSubscription<LxmReceived>? _sub;
  final Map<String, Map<int, SyncRecord>> _pending = {};
  final Map<String, Timer> _gapTimers = {};
  Future<void> _tail = Future.value();
  int _ownSeq = 0;
  bool _started = false;

  /// Applied records of other devices, in order per origin.
  Stream<SyncRecord> get records => _records.stream;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _ownSeq = await store.ownSeq();
    _sub = router.incoming.listen((m) => _enqueue(() => _onMessage(m)));
  }

  Future<void> stop() async {
    _started = false;
    await _sub?.cancel();
    for (final t in _gapTimers.values) {
      t.cancel();
    }
    _gapTimers.clear();
    await _records.close();
  }

  void _enqueue(Future<void> Function() f) {
    _tail = _tail.then((_) => f()).catchError((Object _) {});
  }

  /// Waits for queued inbound handling (tests).
  Future<void> flush() => _tail;

  GroupDevice? _byAddress(List<int> hash) {
    final h = toHex(hash);
    for (final d in state.devices.active) {
      if (toHex(d.lxmfAddress) == h) return d;
    }
    return null;
  }

  /// Makes the siblings known to the router so sending can find them.
  void rememberSiblings() {
    for (final d in state.devices.active) {
      if (d.id == ownId) continue;
      rns.rememberDestination(d.publicKey, 'lxmf', const ['delivery']);
    }
  }

  // ---------------------------------------------------------------- publish

  /// Appends a record to this device's stream and sends it to every sibling
  /// (or only to [to]). Returns the new `seq`.
  Future<int> publish(String kind, Object? data, {Iterable<String>? to}) async {
    _ownSeq += 1;
    final seq = _ownSeq;
    await store.saveOwnSeq(seq);
    final packed = packb({
      'kind': kind,
      'ts': DateTime.now().millisecondsSinceEpoch / 1000,
      'data': data,
    });
    await store.saveRecord(seq, packed);
    if (seq % 100 == 0) await store.pruneRecords(seq - 900);
    await _fanOut(seq, packed, state.epoch, to: to);
    return seq;
  }

  /// Sends a record that is not part of the sequence (`seq` 0) to specific
  /// devices, encrypted with [epoch] (used to hand out a rotated key).
  Future<void> publishTargeted(
    String kind,
    Object? data,
    Iterable<String> to, {
    int? epoch,
  }) async {
    final packed = packb({
      'kind': kind,
      'ts': DateTime.now().millisecondsSinceEpoch / 1000,
      'data': data,
    });
    await _fanOut(0, packed, epoch ?? state.epoch, to: to);
  }

  Future<void> _fanOut(
    int seq,
    Uint8List packed,
    int epoch, {
    Iterable<String>? to,
  }) async {
    final env = await _envelope(seq, packed, epoch);
    final targets = to?.toSet();
    final futures = <Future<void>>[
      for (final t in extraTransports)
        t.send(env, to: to).catchError((Object _) {}),
    ];
    for (final d in state.devices.active) {
      if (d.id == ownId) continue;
      if (targets != null && !targets.contains(d.id)) continue;
      futures.add(_send(d, env));
    }
    await Future.wait(futures);
  }

  Future<Map<String, Object?>> _envelope(
    int seq,
    Uint8List packed,
    int epoch,
  ) async {
    final rec = unpackb(packed)! as Map;
    final blobId = seq == 0
        ? toHex(_random(16))
        : toHex(truncatedHash(utf8.encode('$ownId:$seq')));
    final key = state.chain[epoch];
    if (key == null) throw StateError('no key for epoch $epoch');
    final ct = await VaultCrypto.encryptBlob(
      groupKey: key,
      blobId: blobId,
      deviceId: ownId,
      seq: seq,
      keyEpoch: epoch,
      kind: rec['kind']! as String,
      ts: (rec['ts']! as num).toDouble(),
      data: rec['data'],
    );
    return {
      'v': kDeviceSyncVersion,
      'blob_id': blobId,
      'device_id': ownId,
      'seq': seq,
      'key_epoch': epoch,
      'ct': ct,
    };
  }

  Future<void> _send(GroupDevice d, Map<String, Object?> env) async {
    rns.rememberDestination(d.publicKey, 'lxmf', const ['delivery']);
    try {
      await router.send(
        destinationHash: d.lxmfAddress,
        content: '',
        fields: {
          syncFieldType: syncTypeRecord,
          syncFieldData: packb(env),
        },
        method: LxmfMethod.opportunistic,
      );
    } on Object {
      // queued messages survive in the router; a failed hand-over is healed
      // by the gap request of the receiver
    }
  }

  // ---------------------------------------------------------------- receive

  Future<void> _onMessage(LxmReceived rx) async {
    final m = rx.message;
    if (!m.signatureValidated) return;
    final from = _byAddress(m.sourceHash);
    if (from == null) return; // unknown or removed device
    final type = m.fields[syncFieldType];
    final data = m.fields[syncFieldData];
    if (data is! Uint8List) return;
    if (type == syncTypeRecord) {
      await ingest(data, from: from.id);
    } else if (type == syncTypeGap) {
      await _onGap(from, data);
    }
  }

  /// Applies an envelope received from [from] (any transport: LXMF, bridge
  /// vault). Duplicates are ignored, gaps are requested.
  Future<bool> ingest(Uint8List envelope, {String? from}) async {
    final Object? o;
    try {
      o = unpackb(envelope);
    } on Object {
      return false;
    }
    if (o is! Map) return false;
    final blobId = o['blob_id'];
    final dev = o['device_id'];
    final seq = o['seq'];
    final epoch = o['key_epoch'];
    final ct = o['ct'];
    if (blobId is! String ||
        dev is! String ||
        seq is! int ||
        epoch is! int ||
        ct is! Uint8List ||
        o['v'] != kDeviceSyncVersion) {
      return false;
    }
    if (from != null && from != dev) return false;
    if (dev == ownId || !state.devices.isActive(dev)) return false;
    final VaultBlobPlain plain;
    try {
      plain = await VaultCrypto.decryptBlob(
        ciphertext: ct,
        chain: state.chain,
        blobId: blobId,
        deviceId: dev,
        seq: seq,
        keyEpoch: epoch,
      );
    } on VaultCryptoException {
      return false;
    }
    final rec = SyncRecord(
      origin: dev,
      seq: seq,
      kind: plain.kind,
      ts: plain.ts,
      data: plain.data,
    );
    if (seq == 0) {
      await _apply(rec);
      return true;
    }
    final seen = await store.seen(dev);
    if (seq <= seen) return false; // duplicate
    if (seq > seen + 1) {
      (_pending[dev] ??= {})[seq] = rec;
      _scheduleGap(dev);
      return true;
    }
    await _applySequenced(rec);
    return true;
  }

  Future<void> _applySequenced(SyncRecord first) async {
    var rec = first;
    while (true) {
      await store.setSeen(rec.origin, rec.seq);
      await _apply(rec);
      final next = _pending[rec.origin]?.remove(rec.seq + 1);
      if (next == null) break;
      rec = next;
    }
    if (_pending[rec.origin]?.isEmpty ?? false) {
      _gapTimers.remove(rec.origin)?.cancel();
    }
  }

  void _scheduleGap(String dev) {
    _gapTimers[dev]?.cancel();
    _gapTimers[dev] = Timer(gapDelay, () => _enqueue(() => _requestGap(dev)));
  }

  Future<void> _requestGap(String dev) async {
    final pend = _pending[dev];
    if (pend == null || pend.isEmpty) return;
    final seen = await store.seen(dev);
    final lowest = pend.keys.reduce((a, b) => a < b ? a : b);
    if (lowest <= seen + 1) return;
    final d = state.devices[dev];
    if (d == null || d.removed) return;
    try {
      await router.send(
        destinationHash: d.lxmfAddress,
        content: '',
        fields: {
          syncFieldType: syncTypeGap,
          syncFieldData: packb({'from': seen + 1, 'to': lowest - 1}),
        },
        method: LxmfMethod.opportunistic,
      );
    } on Object {
      // retried by the next out-of-order record
    }
    _scheduleGap(dev);
  }

  Future<void> _onGap(GroupDevice from, Uint8List data) async {
    final o = unpackb(data);
    if (o is! Map || o['from'] is! int || o['to'] is! int) return;
    var a = o['from']! as int;
    var b = o['to']! as int;
    if (a < 1) a = 1;
    if (b > _ownSeq) b = _ownSeq;
    if (b - a > 200) b = a + 200;
    for (var s = a; s <= b; s++) {
      final packed = await store.record(s);
      if (packed == null) continue;
      await _send(from, await _envelope(s, packed, state.epoch));
    }
  }

  // ------------------------------------------------------------ built-ins

  Future<void> _apply(SyncRecord r) async {
    try {
      switch (r.kind) {
        case SyncKind.devices:
          final d = r.data;
          if (d is Map &&
              state.devices.merge(DeviceList.fromList(d['list']).all)) {
            rememberSiblings();
            onStateChanged?.call();
          }
        case SyncKind.name:
          final d = r.data;
          if (d is Map &&
              d['name'] is String &&
              d['rev'] is int &&
              state.mergeName(d['name']! as String, d['rev']! as int)) {
            onStateChanged?.call();
          }
        case SyncKind.ratchets:
          final d = r.data;
          final g = group;
          if (d is Map && g != null && g.ratchets != null) {
            final tb = d['tb'];
            if (tb is int && g.announceTimebase != null) {
              g.announceTimebase!.observe(tb);
            }
            final list = <RatchetEntry>[
              for (final e in (d['list'] as List? ?? const []))
                if (e is Map && e['k'] is Uint8List && e['t'] is int)
                  RatchetEntry(e['k']! as Uint8List, e['t']! as int),
            ];
            await g.mergeRatchets(list);
          }
        case SyncKind.identity:
          final c = IdentityChange.fromMap(r.data);
          if (c != null) {
            final hash = await c.newHash();
            if (state.adoptIdentity(c.gen, hash)) {
              if (c.name.isNotEmpty) state.mergeName(c.name, c.nameRev);
              state.mergeTimebase(c.timebase);
              onStateChanged?.call();
              await onIdentity?.call(c);
            }
          }
        case SyncKind.rekey:
          final d = r.data;
          if (d is Map && d['wrapped'] is Uint8List) {
            final chain = await VaultCrypto.unwrapFromIdentity(
                d['wrapped']! as Uint8List, deviceKey);
            if (chain != null && state.mergeChain(chain)) {
              onStateChanged?.call();
            }
          }
      }
    } on Object {
      // a malformed built-in record never stops the stream
    }
    if (!_records.isClosed) _records.add(r);
  }

  // ------------------------------------------------------------- operations

  /// Announces G from this device (the announcer): a due ratchet rotation is
  /// shared with the siblings first, so a sibling that takes over can decrypt
  /// what was encrypted to the announced ratchet.
  Future<bool> announceGroup(LxmRouter groupRouter) async {
    final g = groupRouter.destination;
    if (g.ratchets != null && g.ratchetRotationAllowed) {
      await g.rotateRatchets();
      await publishRatchets();
    }
    return groupRouter.announce();
  }

  /// Sends the device list (and the shared name) to every sibling.
  Future<void> publishDevices() => publish(SyncKind.devices, {
        'list': state.devices.toList(),
      });

  Future<void> publishName() => publish(SyncKind.name, {
        'name': state.displayName,
        'rev': state.nameRev,
      });

  /// Tells every sibling that the group moved to a new main identity (the
  /// caller already adopted it in [state]). Sent once by the device that
  /// initiated "Change address".
  Future<int> publishIdentity(IdentityChange change) =>
      publish(SyncKind.identity, change.toMap());

  /// Sends the newest [limit] ratchets (all if 0) of the group destination.
  Future<void> publishRatchets({int limit = 8}) {
    final g = group;
    if (g == null || g.ratchets == null) return Future.value();
    final all = g.exportRatchets();
    final part =
        limit == 0 || all.length <= limit ? all : all.sublist(0, limit);
    return publish(SyncKind.ratchets, {
      'list': [
        for (final r in part) {'k': r.key, 't': r.createdAt}
      ],
      'tb': g.announceTimebase?.lastEmitted ?? 0,
    });
  }

  /// Removes [id] from the group: the key rotates, every remaining device
  /// receives the new chain wrapped to its own device key (encrypted with the
  /// old epoch, targeted, so the removed device never sees it), then the
  /// device list with the tombstone follows under the new key.
  Future<GroupDevice?> removeDevice(String id) async {
    if (id == ownId) return null;
    final oldEpoch = state.epoch;
    final d = state.removeDevice(id);
    if (d == null) return null;
    onStateChanged?.call();
    for (final dev in state.devices.active) {
      if (dev.id == ownId) continue;
      final wrapped = await VaultCrypto.wrapToIdentity(
        state.chain,
        Identity.fromPublicKey(dev.publicKey),
      );
      await publishTargeted(
        SyncKind.rekey,
        {'wrapped': wrapped},
        [dev.id],
        epoch: oldEpoch,
      );
    }
    await publishDevices();
    return d;
  }
}
