import 'dart:async';
import 'dart:typed_data';

import '../crypto/hashes.dart';
import '../destination.dart';
import '../identity.dart';
import '../interfaces/interface.dart';
import '../link/link.dart';
import '../link/resource.dart';
import '../msgpack/msgpack.dart';
import '../reticulum.dart';
import '../stamps.dart';
import '../transport/receipt.dart';
import '../transport/transport.dart';
import '../util.dart';
import 'lx_message.dart';
import 'lxm_app_data.dart';
import 'lxm_propagation.dart';
import 'lxm_stamper.dart';
import 'lxm_store.dart';

/// Outbound message state (LXMessage.GENERATING..FAILED, LXMessage.py:15-22).
enum LxmState {
  generating(0x00),
  outbound(0x01),
  sending(0x02),
  sent(0x04),
  delivered(0x08),
  rejected(0xFD),
  cancelled(0xFE),
  failed(0xFF);

  const LxmState(this.code);
  final int code;

  bool get terminal =>
      this == delivered ||
      this == rejected ||
      this == cancelled ||
      this == failed;

  static LxmState fromCode(int c) =>
      values.firstWhere((s) => s.code == c, orElse: () => outbound);
}

/// Router tuning (LXMRouter class constants; shorter values make tests fast).
class LxmRouterConfig {
  const LxmRouterConfig({
    this.maxDeliveryAttempts = 5,
    this.deliveryRetryWait = const Duration(seconds: 10),
    this.pathRequestWait = const Duration(seconds: 7),
    this.maxPathlessTries = 1,
    this.processInterval = const Duration(seconds: 2),
    this.inboundStampCost,
    this.enforceStamps = false,
    this.deliveryPerTransferLimit = 1000 * 1000,
    this.linkTimeout = const Duration(seconds: 60),
    this.fallbackToPropagation = true,
    this.autoSync = true,
    this.propagationSyncInterval = const Duration(minutes: 15),
    this.propagationNodeMaxAge = const Duration(days: 2),
    this.propagationPathWait = const Duration(seconds: 15),
    this.syncTimeout = const Duration(seconds: 120),
    this.nodeUnreachableFor = const Duration(minutes: 10),
    this.nodeWait = const Duration(seconds: 60),
    this.autoSyncMinGap = const Duration(seconds: 30),
    this.propagationStampCostOverride,
  });

  /// LXMRouter.MAX_DELIVERY_ATTEMPTS.
  final int maxDeliveryAttempts;

  /// LXMRouter.DELIVERY_RETRY_WAIT.
  final Duration deliveryRetryWait;

  /// LXMRouter.PATH_REQUEST_WAIT.
  final Duration pathRequestWait;

  /// LXMRouter.MAX_PATHLESS_TRIES.
  final int maxPathlessTries;

  /// How often the outbound queue is processed (PROCESSING_INTERVAL).
  final Duration processInterval;

  /// Stamp value required from senders (announced); null = none.
  final double? inboundStampCost;

  /// Drop inbound messages whose stamp is missing/invalid (default: deliver
  /// them flagged, like LXMRouter without `enforce_stamps`).
  final bool enforceStamps;

  /// Largest accepted inbound resource, bytes.
  final int deliveryPerTransferLimit;

  /// Give up on an outbound link that never became active.
  final Duration linkTimeout;

  /// Fall back to a propagation node when DIRECT/OPPORTUNISTIC delivery
  /// failed after its retries (runtime-changeable, see
  /// [LxmRouter.fallbackToPropagation]).
  final bool fallbackToPropagation;

  /// Sync the inbox on start/connect and on [propagationSyncInterval].
  final bool autoSync;

  /// Interval of the periodic inbox sync while online (null = none).
  final Duration? propagationSyncInterval;

  /// A node not heard for longer than this is not auto-selected.
  final Duration propagationNodeMaxAge;

  /// How long to wait for a path to the propagation node.
  final Duration propagationPathWait;

  /// Overall limit of one inbox sync.
  final Duration syncTimeout;

  /// How long a node that failed repeatedly is skipped by auto-selection.
  final Duration nodeUnreachableFor;

  /// How long a message forced to propagation waits for any node to appear.
  final Duration nodeWait;

  /// Minimum gap between automatic (connect/announce triggered) syncs.
  final Duration autoSyncMinGap;

  /// Use this stamp cost for propagation stamps instead of the node's
  /// announced one (tests, or deliberately cheaper stamps within the node's
  /// flexibility).
  final double? propagationStampCostOverride;
}

/// A state transition of an outbound message.
class LxmOutboundEvent {
  LxmOutboundEvent({
    required this.hash,
    required this.state,
    required this.stage,
    required this.at,
    required this.method,
    this.error,
    this.tag,
    this.attempt = 0,
    this.progress,
  });

  final Uint8List hash;
  final LxmState state;

  /// Fine grained stage for logs: `queued`, `stamp_generated`,
  /// `path_requested`, `link_requested`, `link_established`, `sent`,
  /// `delivered`, `failed`, `retry`, ...
  final String stage;
  final DateTime at;

  /// `LxmfMethod` actually used (after size based upgrades).
  final int method;
  final String? error;
  final String? tag;
  final int attempt;
  final double? progress;

  @override
  String toString() => 'LxmOutboundEvent(${toHex(hash)} $state $stage)';
}

/// Handle for a queued outbound message.
class LxmOutbound {
  LxmOutbound._(this.message, this.tag);

  final LXMessage message;
  final String? tag;
  LxmState state = LxmState.generating;
  String? error;
  int attempts = 0;
  double progress = 0;
  double? stampValue;

  /// Value of the propagation stamp attached for the node (propagated only).
  double? propagationStampValue;

  Uint8List get hash => message.hash!;
  int get method => message.method;

  final _done = Completer<LxmOutbound>();

  /// Completes when the message reached a final state (delivered, failed,
  /// rejected, cancelled).
  Future<LxmOutbound> get done => _done.future;
}

/// A received LXMF message with delivery metadata.
class LxmReceived {
  LxmReceived({
    required this.message,
    required this.method,
    required this.receivedAt,
    this.stampValid,
    this.stampValue,
  });

  final LXMessage message;

  /// `LxmfMethod.opportunistic`, `direct` or `propagated` (via a node).
  final int method;
  final DateTime receivedAt;

  /// null if no stamp was required.
  final bool? stampValid;
  final double? stampValue;
}

/// A peer learned from an `lxmf.delivery` announce.
class LxmPeer {
  LxmPeer({
    required this.hash,
    required this.displayName,
    required this.stampCost,
    required this.supportsCompression,
    required this.hops,
    required this.lastSeen,
  });

  final Uint8List hash;
  final String? displayName;
  final double? stampCost;
  final bool supportsCompression;
  final int hops;
  final DateTime lastSeen;
}

class _Out {
  _Out(this.handle, this.record);
  final LxmOutbound handle;
  final LxmOutboundRecord record;
  DateTime? nextAttempt;
  bool awaitingPath = false;
  bool sentOnPath = false;
  int maxAttempts = 5;
  DateTime? linkRequestedAt;
  Resource? resource;
  bool pathRetried = false;
  _PnPayload? pn;
  bool pnPreparing = false;
  bool fellBack = false;
  DateTime queuedAt = DateTime.now();
  LXMessage get msg => handle.message;
}

class _PnPayload {
  _PnPayload(
      this.packed, this.transientId, this.stampValue, this.cost, this.node);
  final Uint8List packed;
  final String node;
  final Uint8List transientId;
  final double stampValue;
  final double cost;
}

enum _Inbound { delivered, duplicate, dropped, persistFailed, undecryptable }

class _SyncAbort implements Exception {
  const _SyncAbort(this.error);
  final LxmSyncError error;
  String? get detail => null;
}

/// LXMF delivery router (LXMF/LXMRouter.py) for one identity on top of a
/// [Reticulum] node: opportunistic and direct (link / resource) delivery,
/// delivery receipts, retries, path requests, stamps and inbound validation.
/// Offline mail goes through an LXMF propagation node (client side only):
/// [LxmfMethod.propagated] uploads, [syncInbox] downloads.
class LxmRouter {
  LxmRouter._(
    this.rns,
    this.identity,
    this.destination,
    this.config,
    this.store,
    this._displayName,
  );

  final Reticulum rns;
  final Identity identity;

  /// The `lxmf.delivery` destination of [identity].
  final Destination destination;
  final LxmRouterConfig config;
  final LxmStore store;
  String? _displayName;

  final List<_Out> _pending = [];
  final Map<String, Link> _links = {};
  final Set<String> _wired = {};
  final Map<String, Identity> _linkIdentities = {};
  final Map<String, LxmPeer> _peers = {};
  final _incoming = StreamController<LxmReceived>.broadcast();
  final _events = StreamController<LxmOutboundEvent>.broadcast();
  final _peerC = StreamController<LxmPeer>.broadcast();
  final List<StreamSubscription<Object?>> _subs = [];
  final Map<String, DateTime> _pathRequested = {};
  Timer? _timer;
  Timer? _syncTimer;
  bool _processing = false;

  // ---- propagation (client side) ----
  final Map<String, LxmPropagationNode> _nodes = {};
  Uint8List? _pinnedNode;
  Uint8List? _defaultNode;
  Uint8List? _currentNode;
  final Map<String, int> _nodeFailures = {};
  final Map<String, DateTime> _nodeUnreachable = {};
  Link? _pnLink;
  DateTime? _pnLinkRequestedAt;
  _Out? _pnInFlight;
  final _propC = StreamController<void>.broadcast();
  final _syncC = StreamController<LxmSyncProgress>.broadcast();
  LxmSyncProgress _syncProgress =
      const LxmSyncProgress(phase: LxmSyncPhase.idle);
  LxmSyncResult? _lastSync;
  Future<LxmSyncResult>? _syncing;
  bool _syncWanted = false;
  DateTime? _lastAutoSync;

  /// Fall back to the propagation node when direct/opportunistic delivery
  /// fails (setting; default from [LxmRouterConfig.fallbackToPropagation]).
  late bool fallbackToPropagation = config.fallbackToPropagation;

  /// Sync automatically on start/connect/interval.
  late bool autoSync = config.autoSync;

  /// Whether this router may sync the inbox at all.
  ///
  /// Multi-device hook (docs/spikes/device-group.md section 4): a propagation
  /// node deletes a message after the first download (the client's "haves",
  /// LXMRouter.py:1847), so with one identity shared by several devices
  /// exactly one device (the announcer, phase S) may sync. That device
  /// persists first and forwards to its siblings; all other devices set this
  /// to false. Today every device owns its identity, so it stays true.
  bool inboxSyncEnabled = true;

  /// Persists an inbound message **before** it counts as handled. When set it
  /// is awaited for every received message; if it throws, the message is not
  /// acknowledged (a propagation node keeps it) and not delivered.
  Future<void> Function(LxmReceived)? inboundPersister;

  final Set<String> _syncedTransient = {};
  bool _again = false;
  bool _stopped = false;

  /// Our LXMF address (`lxmf.delivery` destination hash).
  Uint8List get address => destination.hash;

  /// Incoming messages (after signature check, dedup and stamp handling).
  Stream<LxmReceived> get incoming => _incoming.stream;

  /// Every outbound state transition.
  Stream<LxmOutboundEvent> get outboundEvents => _events.stream;

  /// Peers learned from announces (emits on each update).
  Stream<LxmPeer> get peerUpdates => _peerC.stream;

  List<LxmPeer> get knownPeers => List.unmodifiable(_peers.values);

  String? get displayName => _displayName;

  /// Creates the delivery destination, registers handlers and restores the
  /// outbound queue from [store].
  static Future<LxmRouter> start(
    Reticulum rns,
    Identity identity, {
    String? displayName,
    LxmRouterConfig config = const LxmRouterConfig(),
    LxmStore? store,
  }) async {
    final dest = await rns.createDestination(
      identity,
      'lxmf',
      const ['delivery'],
      ratchets: true,
    );
    final r = LxmRouter._(
      rns,
      identity,
      dest,
      config,
      store ?? MemoryLxmStore(),
      displayName,
    );
    await r._init();
    return r;
  }

  static final Uint8List _deliveryNameHash =
      Destination.nameHashFor('lxmf', const ['delivery']);
  static final Uint8List _propagationNameHash =
      Destination.nameHashFor('lxmf', const ['propagation']);

  Future<void> _init() async {
    destination
      ..proofStrategy = ProofStrategy.all
      ..onPacket = (data, packet) {
        _onOpportunistic(data);
      }
      ..onLinkEstablished = (l) {
        _wireLink(l as Link);
      }
      ..defaultAppData = _announceData();

    // Peers already known to the transport (persisted announces).
    for (final k in rns.transport.knownDestinations) {
      final id = Identity.fromPublicKey(k.publicKey);
      if (toHex(Destination.hashFor(id, 'lxmf', const ['delivery'])) ==
          toHex(k.destinationHash)) {
        _updatePeer(k.destinationHash, k.appData, 0,
            DateTime.fromMillisecondsSinceEpoch((k.timestamp * 1000).round()));
      }
    }
    for (final k in rns.transport.knownDestinations) {
      final id = Identity.fromPublicKey(k.publicKey);
      if (toHex(Destination.hashFor(id, 'lxmf', const ['propagation'])) ==
          toHex(k.destinationHash)) {
        _updateNode(
            k.destinationHash,
            k.appData,
            rns.transport.hopsTo(k.destinationHash),
            DateTime.fromMillisecondsSinceEpoch((k.timestamp * 1000).round()),
            notify: false);
      }
    }
    _subs.add(rns.announces.listen(_onAnnounce));
    _subs.add(rns.interfaceEvents.listen((e) {
      if (e.state == InterfaceState.online) {
        _kick();
        _syncWanted = true;
        _maybeAutoSync();
      }
    }));

    for (final rec in await store.loadOutbound()) {
      try {
        final m = await LXMessage.unpackFromBytes(rec.packed);
        m
          ..incoming = false
          ..desiredMethod = rec.desiredMethod;
        _classify(m);
        final h = LxmOutbound._(m, rec.tag)
          ..state = LxmState.outbound
          ..attempts = rec.attempts;
        _pending.add(_Out(h, rec));
      } on Object {
        await store.removeOutbound(rec.hash);
      }
    }
    _timer = Timer.periodic(config.processInterval, (_) => _kick());
    if (_pending.isNotEmpty) _kick();
    setSyncInterval(config.propagationSyncInterval);
    _syncWanted = true;
    scheduleMicrotask(_maybeAutoSync);
  }

  // ------------------------------------------------------------------ announce

  Uint8List? _announceData() => _displayName == null
      ? null
      : LxmAnnounceData.pack(
          displayName: _displayName,
          stampCost: config.inboundStampCost,
        );

  /// Updates the display name used in announces. Call [announce] afterwards.
  void setDisplayName(String? name) {
    _displayName = (name == null || name.trim().isEmpty) ? null : name.trim();
    destination.defaultAppData = _announceData();
  }

  /// Announces the delivery destination (LXMRouter.announce).
  Future<bool> announce() =>
      rns.announce(destination, appData: _announceData());

  void _onAnnounce(AnnounceEvent e) {
    final nh = toHex(e.announce.nameHash);
    if (nh == toHex(_propagationNameHash)) {
      _updateNode(e.destinationHash, e.appData, e.hops, DateTime.now());
      return;
    }
    if (nh != toHex(_deliveryNameHash)) return;
    _updatePeer(e.destinationHash, e.appData, e.hops, DateTime.now());
    final o = _pending.any((p) =>
        toHex(p.msg.destinationHash) == toHex(e.destinationHash) &&
        p.awaitingPath);
    if (o) _kick();
  }

  void _updatePeer(
    List<int> hash,
    List<int>? appData,
    int hops,
    DateTime seen,
  ) {
    final d = LxmAnnounceData.parse(appData);
    final p = LxmPeer(
      hash: Uint8List.fromList(hash),
      displayName: d.displayName,
      stampCost: d.stampCost,
      supportsCompression: d.supportsCompression,
      hops: hops,
      lastSeen: seen,
    );
    _peers[toHex(hash)] = p;
    if (!_peerC.isClosed) _peerC.add(p);
  }

  /// The peer for [hash] if an announce was seen.
  LxmPeer? peer(List<int> hash) => _peers[toHex(hash)];

  // ------------------------------------------------------------------- inbound

  void _onOpportunistic(Uint8List data) {
    final bytes = LXMessage.fromOpportunisticPayload(destination.hash, data);
    unawaited(_deliver(bytes, LxmfMethod.opportunistic));
  }

  void _wireLink(Link link) {
    final k = toHex(link.linkId);
    if (!_wired.add(k)) return;
    link
      ..onPacket = (data, packet) {
        unawaited(_deliver(Uint8List.fromList(data), LxmfMethod.direct));
      }
      ..resourceStrategy = ResourceStrategy.app
      ..onResourceAdvertised = (adv) {
        return adv.dataSize <= config.deliveryPerTransferLimit;
      }
      ..onResourceConcluded = (res) {
        if (res.status == ResourceStatus.complete && res.data != null) {
          unawaited(_deliver(res.data!, LxmfMethod.direct));
        }
      }
      ..onRemoteIdentified = (l, id) {
        _linkIdentities[toHex(LXMessage.deliveryHash(id))] = id;
      };
    final prev = link.onClosed;
    link.onClosed = (l) {
      _wired.remove(k);
      prev?.call(l);
    };
  }

  Future<void> _deliver(Uint8List bytes, int method) async {
    await _deliverResult(bytes, method);
  }

  Future<_Inbound> _deliverResult(Uint8List bytes, int method) async {
    try {
      if (bytes.length < 16 + 16 + 64 + 1) return _Inbound.dropped;
      final dest = Uint8List.sublistView(bytes, 0, 16);
      if (toHex(dest) != toHex(destination.hash)) return _Inbound.dropped;
      final src = Uint8List.sublistView(bytes, 16, 32);
      final srcHex = toHex(src);
      final sid = rns.transport.recallIdentity(src) ?? _linkIdentities[srcHex];
      if (sid == null) {
        // Learn the sender so the next message verifies.
        unawaited(rns.requestPath(src).catchError((_) {}));
      }
      final msg = await LXMessage.unpackFromBytes(bytes, sourceIdentity: sid);

      bool? stampValid;
      double? stampValue;
      final cost = config.inboundStampCost;
      if (cost != null && cost > 0) {
        final s = msg.stamp;
        stampValue =
            s == null ? null : await LxmStamper.validate(s, cost, msg.hash!);
        stampValid = stampValue != null;
        if (!stampValid && config.enforceStamps) return _Inbound.dropped;
      }
      if (!await store.claimInbound(msg.hash!)) return _Inbound.duplicate;
      final rx = LxmReceived(
        message: msg,
        method: method,
        receivedAt: DateTime.now(),
        stampValid: stampValid,
        stampValue: stampValue,
      );
      final persist = inboundPersister;
      if (persist != null) {
        try {
          await persist(rx);
        } on Object {
          await store.releaseInbound(msg.hash!);
          return _Inbound.persistFailed;
        }
      }
      if (!_incoming.isClosed) _incoming.add(rx);
      return _Inbound.delivered;
    } on Object {
      // malformed inbound data is dropped like LXMRouter.lxmf_delivery
      return _Inbound.dropped;
    }
  }

  // ------------------------------------------------------------------ outbound

  void _classify(LXMessage m) {
    final payloadLen = m.packed!.length - 16 - 16 - 64;
    final contentSize =
        payloadLen - LXMessage.timestampSize - LXMessage.structOverhead;
    var wanted = m.desiredMethod;
    if (wanted == LxmfMethod.propagated) {
      m.method = wanted;
      m.representation = LxmfRepresentation.unknown;
      return;
    }
    if (wanted == LxmfMethod.opportunistic &&
        contentSize > LXMessage.encryptedPacketMaxContent) {
      wanted = LxmfMethod.direct;
    }
    m.method = wanted;
    m.representation = wanted == LxmfMethod.opportunistic
        ? LxmfRepresentation.packet
        : (contentSize <= LXMessage.linkPacketMaxContent
            ? LxmfRepresentation.packet
            : LxmfRepresentation.resource);
  }

  /// Queues a message for delivery and returns its handle immediately (the
  /// hash is known; a required stamp is generated in the background).
  ///
  /// [method] is [LxmfMethod.opportunistic] (auto-upgraded to direct when it
  /// does not fit a single packet), [LxmfMethod.direct] or
  /// [LxmfMethod.propagated] ("send via node": uploaded to the selected
  /// propagation node, final state [LxmState.sent]).
  /// [tag] is an opaque value echoed in every event (e.g. a DB row id).
  Future<LxmOutbound> send({
    required List<int> destinationHash,
    required Object content,
    Object title = '',
    Map<Object?, Object?>? fields,
    int method = LxmfMethod.opportunistic,
    String? tag,
    double? stampCost,
  }) async {
    if (method != LxmfMethod.opportunistic &&
        method != LxmfMethod.direct &&
        method != LxmfMethod.propagated) {
      throw ArgumentError('unsupported delivery method $method');
    }
    final dh = Uint8List.fromList(destinationHash);
    final msg = LXMessage(
      destinationHash: dh,
      sourceHash: address,
      content: content,
      title: title,
      fields: fields,
      desiredMethod: method,
    );
    await msg.pack(identity);
    if (method == LxmfMethod.propagated) _classify(msg);
    final handle = LxmOutbound._(msg, tag);
    final rec = LxmOutboundRecord(
      hash: msg.hash!,
      destinationHash: dh,
      packed: msg.packed!,
      desiredMethod: method,
      createdAt: DateTime.now(),
      tag: tag,
    );
    final o = _Out(handle, rec);
    _emit(o, LxmState.generating, 'queued');
    unawaited(_prepare(o, stampCost));
    return handle;
  }

  Future<void> _prepare(_Out o, double? stampCost) async {
    try {
      final cost = stampCost ?? peer(o.msg.destinationHash)?.stampCost;
      if (cost != null && cost > 0) {
        final g = await LxmStamper.generate(o.msg.hash!, cost);
        o.handle.stampValue = g.value;
        await o.msg.pack(identity, stamp: g.stamp);
        o.record.packed = o.msg.packed!;
        _emit(o, LxmState.generating, 'stamp_generated');
      }
      if (_stopped || o.handle.state.terminal) return;
      _pending.add(o);
      _emit(o, LxmState.outbound, 'ready');
      _kick();
    } on Object catch (e) {
      _fail(o, 'stamp generation failed: $e');
    }
  }

  /// Cancels a queued message (LXMRouter.cancel_outbound).
  Future<void> cancel(List<int> hash) async {
    final h = toHex(hash);
    for (final o in [..._pending]) {
      if (toHex(o.handle.hash) == h && !o.handle.state.terminal) {
        await o.resource?.cancel();
        _conclude(o, LxmState.cancelled, 'cancelled');
      }
    }
  }

  /// Handles of messages still in the queue.
  List<LxmOutbound> get pending => [for (final o in _pending) o.handle];

  void _emit(_Out o, LxmState s, String stage, {String? error}) {
    final h = o.handle..state = s;
    if (error != null) h.error = error;
    o.record
      ..state = s.code
      ..attempts = h.attempts;
    if (!_events.isClosed) {
      _events.add(LxmOutboundEvent(
        hash: h.hash,
        state: s,
        stage: stage,
        at: DateTime.now(),
        method: h.method,
        error: error,
        tag: h.tag,
        attempt: h.attempts,
        progress: h.progress,
      ));
    }
    if (_pending.contains(o) && !s.terminal) {
      unawaited(store.saveOutbound(o.record));
    }
  }

  void _conclude(_Out o, LxmState s, String stage, {String? error}) {
    if (o.handle.state.terminal) return;
    if (s == LxmState.delivered) o.handle.progress = 1;
    _emit(o, s, stage, error: error);
    _pending.remove(o);
    unawaited(store.removeOutbound(o.record.hash));
    if (!o.handle._done.isCompleted) o.handle._done.complete(o.handle);
  }

  void _fail(_Out o, String error) =>
      _conclude(o, LxmState.failed, 'failed', error: error);

  void _delivered(_Out o) {
    if (o.handle.state == LxmState.delivered) return;
    _conclude(o, LxmState.delivered, 'delivered');
    // Backchannel: reveal our identity on the link we delivered over so the
    // peer can reply on it (LXMRouter.process_outbound).
    final l = _links[toHex(o.msg.destinationHash)];
    if (l != null &&
        l.initiator &&
        l.isActive &&
        _wired.add('id-${toHex(l.linkId)}')) {
      unawaited(() async {
        try {
          await l.identify(identity);
          _wired.remove(toHex(l.linkId));
          _wireLink(l);
        } on Object {
          // best effort
        }
      }());
    }
  }

  void _kick() {
    if (_stopped) return;
    unawaited(_process());
  }

  bool get _anyOnline => rns.interfaces.any((i) => i.online);

  Future<void> _process() async {
    if (_processing) {
      _again = true;
      return;
    }
    _processing = true;
    try {
      do {
        _again = false;
        if (!_anyOnline) break; // hold the queue while offline
        for (final o in [..._pending]) {
          if (_stopped) return;
          try {
            await _processOne(o);
          } on Object catch (e) {
            _fail(o, 'internal error: $e');
          }
        }
      } while (_again);
    } finally {
      _processing = false;
    }
  }

  bool _due(_Out o, List<int> dest) {
    final n = o.nextAttempt;
    if (n == null || DateTime.now().isAfter(n)) return true;
    return o.awaitingPath && rns.transport.hasPath(dest);
  }

  /// LXMRouter.schedule_attempt (RTT estimate simplified to the configured
  /// waits).
  void _schedule(_Out o, {bool pathRequest = false}) {
    final wait =
        pathRequest ? config.pathRequestWait : config.deliveryRetryWait;
    o.nextAttempt = DateTime.now().add(wait);
    o.awaitingPath = pathRequest;
    o.maxAttempts = config.maxDeliveryAttempts;
  }

  void _requestPath(_Out o, List<int> dest) {
    final k = toHex(dest);
    final last = _pathRequested[k];
    if (last != null &&
        DateTime.now().difference(last) < config.pathRequestWait) {
      return;
    }
    _pathRequested[k] = DateTime.now();
    unawaited(rns.requestPath(dest).catchError((_) {}));
    _emit(o, o.handle.state, 'path_requested');
  }

  Future<void> _processOne(_Out o) async {
    final h = o.handle;
    if (h.state.terminal) {
      _pending.remove(o);
      return;
    }
    if (h.state == LxmState.generating) return;
    final dest = o.msg.destinationHash;
    if (h.progress < 0.01) h.progress = 0.01;

    final d = rns.recallDestination(dest, 'lxmf', const ['delivery']);
    final method = o.msg.method;

    if (method == LxmfMethod.propagated) {
      await _propagated(o);
    } else if (method == LxmfMethod.opportunistic) {
      await _opportunistic(o, d, dest);
    } else {
      await _direct(o, d, dest);
    }
  }

  Future<void> _opportunistic(_Out o, Destination? d, Uint8List dest) async {
    final h = o.handle;
    final limit = o.maxAttempts;
    if (h.attempts > limit) {
      if (_due(o, dest)) _failOrFallback(o, 'max delivery attempts reached');
      return;
    }
    if (!_due(o, dest)) return;
    final pathKnown = rns.transport.hasPath(dest);
    o.awaitingPath = false;
    if (d == null) {
      // Identity unknown: only a path request can teach it.
      h.attempts++;
      if (h.attempts > limit) {
        _failOrFallback(o, 'destination unknown, max attempts reached');
        return;
      }
      _requestPath(o, dest);
      _schedule(o, pathRequest: true);
      return;
    }
    if (h.attempts >= config.maxPathlessTries && !pathKnown) {
      h.attempts++;
      o.sentOnPath = false;
      _requestPath(o, dest);
      _schedule(o, pathRequest: true);
      return;
    }
    if (h.attempts == config.maxPathlessTries + 1 &&
        pathKnown &&
        o.sentOnPath) {
      // Previous attempt went out on a path but got no proof: rediscover.
      h.attempts++;
      o.sentOnPath = false;
      rns.transport.expirePath(dest);
      _pathRequested.remove(toHex(dest));
      _requestPath(o, dest);
      o.nextAttempt = DateTime.now().add(config.pathRequestWait);
      o.awaitingPath = true;
      return;
    }
    h.attempts++;
    o.sentOnPath = pathKnown;
    _schedule(o);
    final receipt = await rns.send(d, o.msg.opportunisticPayload);
    h.progress = 0.5;
    _emit(o, LxmState.sent, 'sent');
    if (receipt != null) {
      unawaited(receipt.done.then((r) {
        if (r.status == ReceiptStatus.delivered) _delivered(o);
      }));
    }
  }

  Future<void> _direct(_Out o, Destination? d, Uint8List dest) async {
    final h = o.handle;
    final limit = o.maxAttempts;
    final k = toHex(dest);
    if (h.attempts > limit) {
      if (_due(o, dest)) _failOrFallback(o, 'max delivery attempts reached');
      return;
    }
    final link = _links[k];
    if (link != null) {
      if (link.isActive) {
        if (h.state == LxmState.outbound || h.state == LxmState.sent) {
          await _sendOnLink(o, link, d);
        }
        return;
      }
      if (link.status == LinkStatus.closed) {
        _links.remove(k);
        o.resource = null;
        if (h.state == LxmState.sending) {
          _emit(o, LxmState.outbound, 'link_closed');
        }
        if (h.attempts + 1 < limit) _schedule(o);
        return;
      }
      // pending: give up on it after linkTimeout
      final t = o.linkRequestedAt;
      if (t != null && DateTime.now().difference(t) > config.linkTimeout) {
        unawaited(link.teardown());
      }
      return;
    }
    if (!_due(o, dest)) return;
    h.attempts++;
    o.awaitingPath = false;
    _schedule(o);
    if (h.attempts > limit) {
      _failOrFallback(o, 'max delivery attempts reached');
      return;
    }
    if (d != null && rns.transport.hasPath(dest)) {
      _emit(o, h.state, 'link_requested');
      o.linkRequestedAt = DateTime.now();
      final l = await Link.initiate(
        rns.transport,
        d,
        onEstablished: (_) {
          _emit(o, h.state, 'link_established');
          _kick();
        },
        onClosed: (_) => _kick(),
      );
      _links[k] = l;
      h.progress = 0.03;
    } else {
      _requestPath(o, dest);
      _schedule(o, pathRequest: true);
    }
  }

  Future<void> _sendOnLink(_Out o, Link link, Destination? d) async {
    final h = o.handle;
    _emit(o, LxmState.sending, 'sending');
    final compress = peer(o.msg.destinationHash)?.supportsCompression ?? true;
    if (o.msg.representation == LxmfRepresentation.packet) {
      final receipt = await link.send(o.msg.packed!);
      if (receipt == null) {
        await link.teardown();
        _emit(o, LxmState.outbound, 'link_send_failed');
        return;
      }
      h.progress = 0.5;
      unawaited(receipt.done.then((r) async {
        if (r.status == ReceiptStatus.delivered) {
          _delivered(o);
        } else if (!h.state.terminal) {
          await link.teardown();
          _emit(o, LxmState.outbound, 'proof_timeout');
        }
      }));
    } else {
      h.progress = 0.1;
      final res = await Resource.send(
        link,
        o.msg.packed!,
        autoCompress: compress,
        progressCallback: (r) {
          h.progress = 0.1 + r.progress * 0.9;
        },
        callback: (r) {
          if (r.status == ResourceStatus.complete) {
            _delivered(o);
          } else if (r.status == ResourceStatus.rejected) {
            _conclude(o, LxmState.rejected, 'rejected',
                error: 'receiver rejected the transfer');
          } else if (!h.state.terminal) {
            unawaited(link.teardown());
            _emit(o, LxmState.outbound, 'transfer_failed');
          }
        },
      );
      if (res == null) {
        await link.teardown();
        _emit(o, LxmState.outbound, 'link_send_failed');
        return;
      }
      o.resource = res;
    }
  }

  // =============================================================== propagation
  //
  // Client side of LXMF propagation (LXMRouter.py, LXMPeer.py): node
  // discovery and selection, uploading messages (PROPAGATED method) and
  // syncing the inbox. Kestrel never runs a propagation node.

  /// Fires whenever the node list, the selected node or the sync state
  /// changes (for UI refresh).
  Stream<void> get propagationUpdates => _propC.stream;

  /// Progress of the running inbox sync.
  Stream<LxmSyncProgress> get syncEvents => _syncC.stream;

  LxmSyncProgress get syncProgress => _syncProgress;

  /// Result of the last finished sync, if any.
  LxmSyncResult? get lastSync => _lastSync;

  /// Node pinned by the user (null = automatic selection).
  Uint8List? get pinnedNode => _pinnedNode;

  void _notify() {
    if (!_propC.isClosed) _propC.add(null);
  }

  LxmPropagationNode _fresh(LxmPropagationNode n) =>
      rns.transport.hasPath(n.hash)
          ? n.copyWith(hops: rns.transport.hopsTo(n.hash))
          : n;

  /// Propagation nodes heard so far, nearest first.
  List<LxmPropagationNode> get propagationNodes {
    final l = [for (final n in _nodes.values) _fresh(n)];
    l.sort((a, b) {
      final h = a.hops.compareTo(b.hops);
      return h != 0 ? h : b.lastSeen.compareTo(a.lastSeen);
    });
    return l;
  }

  /// The node currently used for uploads and syncs: the pinned node, else
  /// the sticky automatic choice (fewest hops among recently heard, enabled,
  /// reachable nodes).
  Uint8List? get activeNode {
    final now = DateTime.now();
    _nodeUnreachable.removeWhere((_, t) => t.isBefore(now));
    final nodes = [for (final n in _nodes.values) _fresh(n)];
    var n = PropagationNodeSelector.select(
      nodes,
      now: now,
      pinned: _pinnedNode,
      preferred: _defaultNode,
      current: _currentNode,
      maxAge: config.propagationNodeMaxAge,
      unreachable: _nodeUnreachable.keys.toSet(),
    );
    // Everything marked unreachable: try anyway rather than do nothing.
    n ??= PropagationNodeSelector.select(
      nodes,
      now: now,
      current: _currentNode,
      maxAge: config.propagationNodeMaxAge,
    );
    // Nothing else known: try the (unreachable) default anyway.
    n ??= _defaultNode;
    final changed = (n == null) != (_currentNode == null) ||
        (n != null && toHex(n) != toHex(_currentNode!));
    _currentNode = n;
    if (changed) _notify();
    return n;
  }

  /// Node preferred while nothing is pinned (null = none: plain automatic
  /// selection). Falls back to automatic selection for as long as it is
  /// marked unreachable, then is retried.
  Uint8List? get defaultNode => _defaultNode;

  /// Whether [hash] is currently skipped after repeated failures.
  bool isNodeUnreachable(List<int> hash) {
    final t = _nodeUnreachable[toHex(hash)];
    return t != null && t.isAfter(DateTime.now());
  }

  /// Sets the default node (see [defaultNode]); asks for a path to it if it
  /// has not been heard yet.
  void setDefaultNode(List<int>? hash) {
    _defaultNode = hash == null ? null : Uint8List.fromList(hash);
    _currentNode = null;
    if (_defaultNode != null &&
        _pinnedNode == null &&
        !_nodes.containsKey(toHex(_defaultNode!))) {
      unawaited(rns.requestPath(_defaultNode!).catchError((_) {}));
    }
    _notify();
    _kick();
    _maybeAutoSync();
  }

  /// Pins [hash] as the propagation node (null = automatic selection).
  void setPinnedNode(List<int>? hash) {
    _pinnedNode = hash == null ? null : Uint8List.fromList(hash);
    _currentNode = null;
    final l = _pnLink;
    if (l != null &&
        (_pinnedNode == null ||
            toHex(l.destination!.hash) != toHex(_pinnedNode!))) {
      unawaited(l.teardown());
      _pnLink = null;
    }
    final want = _pinnedNode ?? _defaultNode;
    if (want != null && !_nodes.containsKey(toHex(want))) {
      unawaited(rns.requestPath(want).catchError((_) {}));
    }
    _syncWanted = true;
    _notify();
    _kick();
    _maybeAutoSync();
  }

  void _updateNode(
    List<int> hash,
    List<int>? appData,
    int hops,
    DateTime seen, {
    bool notify = true,
  }) {
    final d = PropagationNodeData.parse(appData);
    if (d == null) return;
    final k = toHex(hash);
    _nodes[k] = LxmPropagationNode(
      hash: Uint8List.fromList(hash),
      data: d,
      hops: hops,
      lastSeen: seen,
    );
    if (notify) {
      // Heard from it: it is reachable again.
      _nodeUnreachable.remove(k);
      _nodeFailures.remove(k);
      _notify();
      _kick();
      _maybeAutoSync();
    }
  }

  void _noteNode(String key, bool ok) {
    if (ok) {
      _nodeFailures.remove(key);
      _nodeUnreachable.remove(key);
      return;
    }
    final n = (_nodeFailures[key] ?? 0) + 1;
    _nodeFailures[key] = n;
    if (n >= 2) {
      _nodeUnreachable[key] = DateTime.now().add(config.nodeUnreachableFor);
      _nodeFailures.remove(key);
      _notify();
    }
  }

  // ---- fallback --------------------------------------------------------

  void _failOrFallback(_Out o, String error) {
    if (!_tryFallback(o, error)) _fail(o, error);
  }

  /// Re-routes a message whose direct/opportunistic delivery gave up to the
  /// propagation node (once).
  bool _tryFallback(_Out o, String error) {
    if (!fallbackToPropagation || o.fellBack) return false;
    if (o.msg.desiredMethod == LxmfMethod.propagated) return false;
    if (activeNode == null) return false;
    // Encrypting for the node needs the recipient's public key.
    if (rns.transport.recallIdentity(o.msg.destinationHash) == null) {
      return false;
    }
    o
      ..fellBack = true
      ..pn = null
      ..resource = null
      ..nextAttempt = null
      ..awaitingPath = false
      ..queuedAt = DateTime.now();
    o.msg
      ..desiredMethod = LxmfMethod.propagated
      ..method = LxmfMethod.propagated
      ..representation = LxmfRepresentation.unknown;
    o.record.desiredMethod = LxmfMethod.propagated;
    o.handle
      ..attempts = 0
      ..error = error;
    _emit(o, LxmState.outbound, 'fallback_propagated');
    _kick();
    return true;
  }

  // ---- upload ----------------------------------------------------------

  Future<void> _propagated(_Out o) async {
    final h = o.handle;
    if (h.state == LxmState.sending) return; // transfer in flight
    if (o.pnPreparing) return;
    final nodeHash = activeNode;
    if (nodeHash == null) {
      if (DateTime.now().difference(o.queuedAt) > config.nodeWait) {
        _fail(o, 'no propagation node available');
      }
      return;
    }
    if (h.attempts > o.maxAttempts) {
      if (_due(o, nodeHash)) _fail(o, 'max delivery attempts reached');
      return;
    }
    final nk = toHex(nodeHash);
    final node = _nodes[nk];

    // 1. payload: encrypted for the recipient and stamped for the node.
    final pn = o.pn;
    if (pn == null || pn.node != nk) {
      o.pn = null;
      final data = node?.data;
      if (data == null) {
        // Node configuration (stamp cost, limits) unknown: a path request
        // makes it re-announce.
        if (_due(o, nodeHash)) {
          h.attempts++;
          _requestPath(o, nodeHash);
          _schedule(o, pathRequest: true);
        }
        return;
      }
      if (!data.enabled) {
        _fail(o, 'propagation node is not accepting messages');
        return;
      }
      unawaited(_preparePn(o, data, nk));
      return;
    }

    // 2. link to the node.
    final link = _pnLink;
    if (link != null && link.isActive) {
      if (_pnInFlight == null && h.state == LxmState.outbound) {
        await _sendToNode(o, link, node!.data);
      }
      return;
    }
    if (link != null && link.status != LinkStatus.closed) {
      final t = _pnLinkRequestedAt;
      if (t != null && DateTime.now().difference(t) > config.linkTimeout) {
        unawaited(link.teardown());
      }
      return;
    }
    _pnLink = null;
    if (!_due(o, nodeHash)) return;
    h.attempts++;
    o.awaitingPath = false;
    _schedule(o);
    if (h.attempts > o.maxAttempts) {
      _noteNode(nk, false);
      _fail(o, 'max delivery attempts reached');
      return;
    }
    final nd = rns.recallDestination(nodeHash, 'lxmf', const ['propagation']);
    if (nd != null && rns.transport.hasPath(nodeHash)) {
      _emit(o, h.state, 'link_requested');
      await _startPnLink(nd);
    } else {
      _requestPath(o, nodeHash);
      _schedule(o, pathRequest: true);
    }
  }

  final Set<Link> _pnActivated = {};

  Future<Link> _startPnLink(Destination nd) async {
    _pnLinkRequestedAt = DateTime.now();
    Link? self;
    final l = await Link.initiate(
      rns.transport,
      nd,
      onEstablished: (l) {
        _pnActivated.add(l);
        _kick();
      },
      onClosed: (l) => _pnLinkClosed(l),
    );
    self = l;
    l.onPacket = _pnSignal;
    _pnLink = self;
    return l;
  }

  void _pnLinkClosed(Link l) {
    if (identical(_pnLink, l)) _pnLink = null;
    final activated = _pnActivated.remove(l);
    if (!activated && l.destination != null) {
      _noteNode(toHex(l.destination!.hash), false);
    }
    final f = _pnInFlight;
    if (f != null && f.handle.state == LxmState.sending) {
      f.resource = null;
      _pnInFlight = null;
      _emit(f, LxmState.outbound, 'link_closed');
    }
    _kick();
  }

  /// Signalling packets from the node on the upload link
  /// (`propagation_transfer_signalling_packet`, LXMRouter.py:3042).
  void _pnSignal(Uint8List data, Object packet) {
    try {
      final u = unpackb(data);
      if (u is List<Object?> && u.isNotEmpty && u[0] == _errInvalidStamp) {
        final f = _pnInFlight;
        _pnInFlight = null;
        if (f != null) {
          _conclude(f, LxmState.rejected, 'rejected',
              error: 'propagation node rejected the stamp');
        }
      }
    } on Object {
      // ignore malformed signalling
    }
  }

  /// LXMPeer.ERROR_* codes (LXMPeer.py:24-31).
  static const int _errNoIdentity = 0xf0;
  static const int _errNoAccess = 0xf1;
  static const int _errInvalidStamp = 0xf5;

  Future<void> _preparePn(
    _Out o,
    PropagationNodeData data,
    String nodeKey,
  ) async {
    o.pnPreparing = true;
    try {
      final dest = o.msg.destinationHash;
      final recipient = rns.transport.recallIdentity(dest);
      if (recipient == null) {
        _fail(o, 'recipient identity unknown, cannot encrypt');
        return;
      }
      final pp = await o.msg.propagationPacked(
        recipient,
        now: unixNow(),
        ratchet: rns.transport.recallRatchet(dest),
      );
      final size = pp.lxmfData.length + LxmStamper.stampSize;
      if (size > data.transferLimitKb * 1000) {
        _fail(
          o,
          'message too large for the propagation node '
          '($size bytes > ${data.transferLimitKb} kB)',
        );
        return;
      }
      final cost = (config.propagationStampCostOverride ?? data.stampCost)
          .clamp(0, Stamps.costCap)
          .toDouble();
      final g = await LxmStamper.generatePn(pp.transientId, cost);
      if (_stopped || o.handle.state.terminal) return;
      o.handle.propagationStampValue = g.value;
      o.pn = _PnPayload(
        pp.withStamp(g.stamp),
        pp.transientId,
        g.value,
        cost,
        nodeKey,
      );
      _emit(o, o.handle.state, 'pn_stamp_generated');
    } on Object catch (e) {
      _fail(o, 'propagation preparation failed: $e');
    } finally {
      o.pnPreparing = false;
      _kick();
    }
  }

  Future<void> _sendToNode(_Out o, Link link, PropagationNodeData data) async {
    final h = o.handle;
    final pn = o.pn!;
    _pnInFlight = o;
    _emit(o, LxmState.sending, 'sending');
    if (pn.packed.length <= LXMessage.linkPacketMaxContent) {
      final receipt = await link.send(pn.packed);
      if (receipt == null) {
        _pnInFlight = null;
        await link.teardown();
        _emit(o, LxmState.outbound, 'link_send_failed');
        return;
      }
      h.progress = 0.5;
      unawaited(receipt.done.then((r) async {
        if (h.state.terminal) return;
        if (r.status == ReceiptStatus.delivered) {
          _propagatedSent(o);
        } else {
          if (identical(_pnInFlight, o)) _pnInFlight = null;
          await link.teardown();
          _emit(o, LxmState.outbound, 'proof_timeout');
        }
      }));
    } else {
      if (pn.packed.length > data.syncLimitKb * 1000) {
        _pnInFlight = null;
        _fail(
          o,
          'transfer exceeds the propagation node sync limit '
          '(${data.syncLimitKb} kB)',
        );
        return;
      }
      h.progress = 0.1;
      final res = await Resource.send(
        link,
        pn.packed,
        appFlag: true,
        progressCallback: (r) {
          h.progress = 0.1 + r.progress * 0.9;
        },
        callback: (r) {
          if (h.state.terminal) return;
          if (r.status == ResourceStatus.complete) {
            _propagatedSent(o);
          } else if (r.status == ResourceStatus.rejected) {
            if (identical(_pnInFlight, o)) _pnInFlight = null;
            _conclude(o, LxmState.rejected, 'rejected',
                error: 'propagation node refused the transfer');
          } else {
            if (identical(_pnInFlight, o)) _pnInFlight = null;
            unawaited(link.teardown());
            _emit(o, LxmState.outbound, 'transfer_failed');
          }
        },
      );
      if (res == null) {
        _pnInFlight = null;
        await link.teardown();
        _emit(o, LxmState.outbound, 'link_send_failed');
        return;
      }
      o.resource = res;
    }
  }

  /// The node holds the message: final state [LxmState.sent] (LXMessage
  /// `__mark_propagated`).
  void _propagatedSent(_Out o) {
    if (o.handle.state.terminal || !_pending.contains(o)) return;
    if (identical(_pnInFlight, o)) _pnInFlight = null;
    final pn = o.pn;
    if (pn != null) _noteNode(pn.node, true);
    o.handle.progress = 1;
    _pending.remove(o);
    _emit(o, LxmState.sent, 'propagated');
    unawaited(store.removeOutbound(o.record.hash));
    if (!o.handle._done.isCompleted) o.handle._done.complete(o.handle);
    _kick();
  }

  // ---- inbox sync ------------------------------------------------------

  void _setSync(
    LxmSyncPhase phase, {
    Uint8List? node,
    double progress = 0,
    int listed = 0,
    int downloaded = 0,
  }) {
    _syncProgress = LxmSyncProgress(
      phase: phase,
      node: node,
      progress: progress,
      listed: listed,
      downloaded: downloaded,
    );
    if (!_syncC.isClosed) _syncC.add(_syncProgress);
    _notify();
  }

  LxmSyncResult _finishSync(LxmSyncResult r) {
    _lastSync = r;
    _setSync(
      r.ok ? LxmSyncPhase.complete : LxmSyncPhase.failed,
      node: r.node,
      progress: r.ok ? 1 : 0,
      listed: r.listed,
      downloaded: r.downloaded,
    );
    return r;
  }

  /// Downloads the messages waiting on the propagation node (LXMRouter
  /// `request_messages_from_propagation_node`).
  ///
  /// Safety: each message is decrypted, deduplicated by LXMF message hash and
  /// persisted (see [inboundPersister]) **before** the node is told to delete
  /// it (the "haves"). A message that fails to decrypt or persist stays on the
  /// node. Concurrent calls share one run.
  Future<LxmSyncResult> syncInbox({bool force = false}) {
    final running = _syncing;
    if (running != null) return running;
    if (_stopped) {
      return Future.value(
        LxmSyncResult(error: LxmSyncError.stopped, at: DateTime.now()),
      );
    }
    if (!inboxSyncEnabled && !force) {
      return Future.value(
        LxmSyncResult(error: LxmSyncError.disabled, at: DateTime.now()),
      );
    }
    final f = _runSync().whenComplete(() => _syncing = null);
    _syncing = f;
    return f;
  }

  Future<LxmSyncResult> _runSync() async {
    final started = DateTime.now();
    final nodeHash = activeNode;
    LxmSyncResult early(LxmSyncError e, {String? detail}) => _finishSync(
          LxmSyncResult(
              error: e, at: DateTime.now(), node: nodeHash, detail: detail),
        );
    if (nodeHash == null) return early(LxmSyncError.noNode);
    final nk = toHex(nodeHash);
    final info = _nodes[nk];
    if (info != null && !info.enabled) return early(LxmSyncError.nodeDisabled);
    if (!_anyOnline) return early(LxmSyncError.noPath, detail: 'offline');

    var listed = 0, downloaded = 0, delivered = 0, duplicates = 0;
    var undecryptable = 0, persistFailed = 0, purged = 0, remaining = 0;
    LxmSyncResult result(LxmSyncError e, {String? detail}) => _finishSync(
          LxmSyncResult(
            error: e,
            at: DateTime.now(),
            node: nodeHash,
            listed: listed,
            downloaded: downloaded,
            delivered: delivered,
            duplicates: duplicates,
            undecryptable: undecryptable,
            persistFailed: persistFailed,
            purged: purged,
            remaining: remaining,
            detail: detail,
          ),
        );

    Link? link;
    try {
      final deadline = started.add(config.syncTimeout);
      double secondsLeft() {
        final ms = deadline.difference(DateTime.now()).inMilliseconds;
        return ms <= 0 ? 0.001 : ms / 1000;
      }

      _setSync(LxmSyncPhase.pathRequested, node: nodeHash);
      if (!rns.transport.hasPath(nodeHash)) {
        final ok = await rns.awaitPath(
          nodeHash,
          timeout: config.propagationPathWait,
        );
        if (!ok) {
          _noteNode(nk, false);
          return result(LxmSyncError.noPath);
        }
      }
      final nd = rns.recallDestination(
        nodeHash,
        'lxmf',
        const ['propagation'],
      );
      if (nd == null) {
        _noteNode(nk, false);
        return result(LxmSyncError.noPath, detail: 'node identity unknown');
      }

      _setSync(LxmSyncPhase.linkEstablishing, node: nodeHash);
      link = await _syncLink(nd);
      if (link == null) {
        _noteNode(nk, false);
        return result(LxmSyncError.linkFailed);
      }
      await link.identify(identity);

      final skip = <String>{};
      final limitKb = config.deliveryPerTransferLimit ~/ 1000;
      for (var round = 0; round < 20; round++) {
        if (_stopped) return result(LxmSyncError.stopped);
        _setSync(LxmSyncPhase.listing,
            node: nodeHash, listed: listed, downloaded: downloaded);
        final listResp = await _syncRequest(
          link,
          <Object?>[null, null],
          secondsLeft(),
        );
        if (listResp is! List<Object?>) {
          throw const _SyncAbort(LxmSyncError.invalidResponse);
        }
        final ids = [
          for (final e in listResp)
            if (e is Uint8List && e.length == 32) e,
        ];
        if (round == 0) listed = ids.length;
        final haves = <Uint8List>[];
        final wants = <Uint8List>[];
        for (final id in ids) {
          final hx = toHex(id);
          if (skip.contains(hx)) continue;
          (_syncedTransient.contains(hx) ? haves : wants).add(id);
        }
        remaining = skip.length;
        if (wants.isEmpty && haves.isEmpty) break;

        if (wants.isEmpty) {
          // Already persisted earlier but never confirmed: confirm now.
          await _syncRequest(link, <Object?>[null, haves], secondsLeft());
          purged += haves.length;
          for (final id in haves) {
            _syncedTransient.remove(toHex(id));
          }
          break;
        }

        _setSync(LxmSyncPhase.receiving,
            node: nodeHash, listed: listed, downloaded: downloaded);
        final got = await _syncRequest(
          link,
          <Object?>[wants, haves, limitKb],
          secondsLeft(),
          onProgress: (rr) => _setSync(LxmSyncPhase.receiving,
              node: nodeHash,
              progress: rr.progress,
              listed: listed,
              downloaded: downloaded),
        );
        if (got is! List<Object?>) {
          throw const _SyncAbort(LxmSyncError.invalidResponse);
        }
        purged += haves.length; // purged by the node with this request
        for (final id in haves) {
          _syncedTransient.remove(toHex(id));
        }

        // Persist first ...
        _setSync(LxmSyncPhase.persisting,
            node: nodeHash, listed: listed, downloaded: downloaded);
        final confirm = <Uint8List>[];
        var returned = 0;
        for (final item in got) {
          if (item is! Uint8List) continue;
          returned++;
          downloaded++;
          final tid = sha256(item);
          switch (await _ingestPropagated(item)) {
            case _Inbound.delivered:
              delivered++;
              confirm.add(tid);
            case _Inbound.duplicate:
              duplicates++;
              confirm.add(tid);
            case _Inbound.dropped:
              confirm.add(tid); // never deliverable: do not loop on it
            case _Inbound.undecryptable:
              undecryptable++;
              skip.add(toHex(tid));
            case _Inbound.persistFailed:
              persistFailed++;
              skip.add(toHex(tid));
          }
        }
        // ... then tell the node what we have (this deletes them there).
        if (confirm.isNotEmpty) {
          for (final id in confirm) {
            _syncedTransient.add(toHex(id));
          }
          _setSync(LxmSyncPhase.confirming,
              node: nodeHash, listed: listed, downloaded: downloaded);
          try {
            await _syncRequest(link, <Object?>[null, confirm], secondsLeft());
            purged += confirm.length;
            for (final id in confirm) {
              _syncedTransient.remove(toHex(id));
            }
          } on _SyncAbort {
            // Persisted but unconfirmed: retried (as haves) next time.
          }
        }
        remaining = skip.length + (wants.length - returned);
        // Everything we asked for came back: no need to list again.
        if (returned >= wants.length) break;
        if (returned == 0) break;
      }
      _noteNode(nk, true);
      return result(LxmSyncError.none);
    } on _SyncAbort catch (e) {
      if (link != null) _dropPnLink(link);
      if (e.error != LxmSyncError.noAccess &&
          e.error != LxmSyncError.noIdentity) {
        _noteNode(nk, false);
      }
      return result(e.error, detail: e.detail);
    } on Object catch (e) {
      if (link != null) _dropPnLink(link);
      _noteNode(nk, false);
      return result(LxmSyncError.transferFailed, detail: '$e');
    }
  }

  void _dropPnLink(Link l) {
    if (identical(_pnLink, l)) _pnLink = null;
    unawaited(l.teardown());
  }

  Future<Link?> _syncLink(Destination nd) async {
    var l = _pnLink;
    if (l != null && l.status == LinkStatus.closed) {
      _pnLink = null;
      l = null;
    }
    l ??= await _startPnLink(nd);
    try {
      await l.established.timeout(config.linkTimeout);
    } on Object {
      _dropPnLink(l);
      return null;
    }
    return l.isActive ? l : null;
  }

  /// One request/response on the node link; throws [_SyncAbort] on failure.
  Future<Object?> _syncRequest(
    Link link,
    Object? data,
    double timeoutSeconds, {
    void Function(RequestReceipt)? onProgress,
  }) async {
    final rr = await link.request(
      '/get',
      data: data,
      timeout: timeoutSeconds,
      onProgress: onProgress,
    );
    if (rr == null) throw const _SyncAbort(LxmSyncError.transferFailed);
    await rr.done;
    if (rr.status != RequestStatus.ready) {
      throw _SyncAbort(
        rr.status == RequestStatus.failed
            ? LxmSyncError.timeout
            : LxmSyncError.transferFailed,
      );
    }
    final r = rr.response;
    if (r == _errNoIdentity) throw const _SyncAbort(LxmSyncError.noIdentity);
    if (r == _errNoAccess) throw const _SyncAbort(LxmSyncError.noAccess);
    return r;
  }

  /// Decrypts one `destination_hash || encrypted` blob from the node and runs
  /// it through the normal delivery pipeline (signature, stamp, dedup by
  /// message hash, persist).
  Future<_Inbound> _ingestPropagated(Uint8List lxmfData) async {
    try {
      if (lxmfData.length < LXMessage.lxmfOverhead) return _Inbound.dropped;
      final dest = Uint8List.sublistView(lxmfData, 0, 16);
      if (toHex(dest) != toHex(destination.hash)) return _Inbound.dropped;
      final dec = await destination.decrypt(
        Uint8List.sublistView(lxmfData, 16),
        ratchets: destination.ratchets,
        enforceRatchets: destination.enforceRatchets,
      );
      if (dec == null) return _Inbound.undecryptable;
      return await _deliverResult(
        Uint8List.fromList([...dest, ...dec]),
        LxmfMethod.propagated,
      );
    } on Object {
      return _Inbound.undecryptable;
    }
  }

  /// Sets the periodic sync interval (null disables it).
  void setSyncInterval(Duration? d) {
    _syncTimer?.cancel();
    _syncTimer = null;
    if (d == null || _stopped) return;
    _syncTimer = Timer.periodic(d, (_) {
      _syncWanted = true;
      _maybeAutoSync(force: true);
    });
  }

  void _maybeAutoSync({bool force = false}) {
    if (_stopped || !autoSync || !inboxSyncEnabled || !_syncWanted) return;
    if (!_anyOnline || _syncing != null) return;
    if (activeNode == null) return; // wait until a node is heard
    final last = _lastAutoSync;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < config.autoSyncMinGap) {
      return;
    }
    _lastAutoSync = DateTime.now();
    _syncWanted = false;
    unawaited(syncInbox());
  }

  // ------------------------------------------------------------------ lifecycle

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _syncTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    for (final l in _links.values) {
      unawaited(l.teardown());
    }
    unawaited(_pnLink?.teardown());
    await _incoming.close();
    await _events.close();
    await _peerC.close();
    await _propC.close();
    await _syncC.close();
  }
}
