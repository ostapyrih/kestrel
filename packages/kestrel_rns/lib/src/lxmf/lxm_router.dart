import 'dart:async';
import 'dart:typed_data';

import '../destination.dart';
import '../identity.dart';
import '../interfaces/interface.dart';
import '../link/link.dart';
import '../link/resource.dart';
import '../reticulum.dart';
import '../transport/receipt.dart';
import '../transport/transport.dart';
import '../util.dart';
import 'lx_message.dart';
import 'lxm_app_data.dart';
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

  /// `LxmfMethod.opportunistic` or `direct`.
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
  LXMessage get msg => handle.message;
}

/// LXMF delivery router (LXMF/LXMRouter.py) for one identity on top of a
/// [Reticulum] node: opportunistic and direct (link / resource) delivery,
/// delivery receipts, retries, path requests, stamps and inbound validation.
/// Propagated delivery is Phase 5 (the API accepts [LxmfMethod.propagated]
/// but throws [UnsupportedError]).
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
  bool _processing = false;
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
    _subs.add(rns.announces.listen(_onAnnounce));
    _subs.add(rns.interfaceEvents.listen((e) {
      if (e.state == InterfaceState.online) _kick();
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
    if (toHex(e.announce.nameHash) != toHex(_deliveryNameHash)) return;
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
    try {
      if (bytes.length < 16 + 16 + 64 + 1) return;
      final dest = Uint8List.sublistView(bytes, 0, 16);
      if (toHex(dest) != toHex(destination.hash)) return;
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
        if (!stampValid && config.enforceStamps) return;
      }
      if (!await store.claimInbound(msg.hash!)) return;
      if (_incoming.isClosed) return;
      _incoming.add(LxmReceived(
        message: msg,
        method: method,
        receivedAt: DateTime.now(),
        stampValid: stampValid,
        stampValue: stampValue,
      ));
    } on Object {
      // malformed inbound data is dropped like LXMRouter.lxmf_delivery
    }
  }

  // ------------------------------------------------------------------ outbound

  void _classify(LXMessage m) {
    final payloadLen = m.packed!.length - 16 - 16 - 64;
    final contentSize =
        payloadLen - LXMessage.timestampSize - LXMessage.structOverhead;
    var wanted = m.desiredMethod;
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
  /// does not fit a single packet) or [LxmfMethod.direct].
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
    if (method == LxmfMethod.propagated) {
      throw UnsupportedError('Propagated delivery arrives in Phase 5');
    }
    if (method != LxmfMethod.opportunistic && method != LxmfMethod.direct) {
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

    if (method == LxmfMethod.opportunistic) {
      await _opportunistic(o, d, dest);
    } else {
      await _direct(o, d, dest);
    }
  }

  Future<void> _opportunistic(_Out o, Destination? d, Uint8List dest) async {
    final h = o.handle;
    final limit = o.maxAttempts;
    if (h.attempts > limit) {
      if (_due(o, dest)) _fail(o, 'max delivery attempts reached');
      return;
    }
    if (!_due(o, dest)) return;
    final pathKnown = rns.transport.hasPath(dest);
    o.awaitingPath = false;
    if (d == null) {
      // Identity unknown: only a path request can teach it.
      h.attempts++;
      if (h.attempts > limit) {
        _fail(o, 'destination unknown, max attempts reached');
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
      if (_due(o, dest)) _fail(o, 'max delivery attempts reached');
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
      _fail(o, 'max delivery attempts reached');
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

  // ------------------------------------------------------------------ lifecycle

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    for (final l in _links.values) {
      unawaited(l.teardown());
    }
    await _incoming.close();
    await _events.close();
    await _peerC.close();
  }
}
