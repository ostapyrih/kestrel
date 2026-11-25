import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/curves.dart';
import '../crypto/hashes.dart';
import '../crypto/random.dart';
import '../crypto/token.dart';
import '../destination.dart';
import '../identity.dart';
import '../interfaces/interface.dart';
import '../msgpack/msgpack.dart';
import '../packet.dart';
import '../transport/receipt.dart';
import '../transport/transport.dart';
import '../util.dart';
import 'resource.dart';

/// Link lifecycle (Link.PENDING..CLOSED, Link.py:84-88).
enum LinkStatus { pending, handshake, active, stale, closed }

/// Why a link closed (Link.TIMEOUT.. , Link.py:90-93).
enum TeardownReason {
  timeout,
  initiatorClosed,
  destinationClosed,
  stampFailure
}

/// What to do with resources advertised by the peer (Link.ACCEPT_*).
enum ResourceStrategy { none, app, all }

/// State of a [RequestReceipt] (RequestReceipt.FAILED..READY).
enum RequestStatus { failed, sent, delivered, receiving, ready }

/// Handle for a request sent over a link (RequestReceipt, Link.py:1461).
class RequestReceipt {
  RequestReceipt._(
    this.link,
    this.requestId,
    this.timeout,
    this.requestSize,
    this.maxResponseSize,
    this.onProgress,
  ) : sentAt = DateTime.now();

  final Link link;
  final Uint8List requestId;
  final double timeout;
  final int requestSize;
  final int? maxResponseSize;
  final void Function(RequestReceipt)? onProgress;
  final DateTime sentAt;

  RequestStatus status = RequestStatus.sent;
  double progress = 0;
  Object? response;
  Object? metadata;
  int? responseSize;
  int? responseTransferSize;
  DateTime? concludedAt;
  Timer? _timer;
  final _done = Completer<RequestReceipt>();

  /// Completes (never with an error) when the request is [RequestStatus.ready]
  /// or [RequestStatus.failed].
  Future<RequestReceipt> get done => _done.future;

  bool get concluded =>
      status == RequestStatus.ready || status == RequestStatus.failed;

  /// Round trip of the request (Link.py get_response_time).
  Duration? get responseTime =>
      status == RequestStatus.ready ? concludedAt!.difference(sentAt) : null;

  void _startTimer(double seconds) {
    _timer?.cancel();
    _timer = Timer(
      Duration(microseconds: (seconds * 1e6).round()),
      _timedOut,
    );
  }

  void _timedOut() {
    if (link._pending.contains(this) &&
        (status == RequestStatus.sent || status == RequestStatus.delivered)) {
      _fail();
    }
  }

  void _fail() {
    status = RequestStatus.failed;
    concludedAt = DateTime.now();
    _timer?.cancel();
    link._pending.remove(this);
    if (!_done.isCompleted) _done.complete(this);
  }

  void _ready(Object? resp, Object? meta) {
    if (status == RequestStatus.failed) return;
    progress = 1.0;
    response = resp;
    metadata = meta;
    status = RequestStatus.ready;
    concludedAt = DateTime.now();
    _timer?.cancel();
    onProgress?.call(this);
    if (!_done.isCompleted) _done.complete(this);
  }

  void _resourceProgress(Resource r) {
    if (status == RequestStatus.failed) {
      unawaited(r.cancel());
      return;
    }
    status = RequestStatus.receiving;
    progress = r.progress;
    onProgress?.call(this);
  }
}

/// An established (or establishing) Reticulum link (RNS/Link.py): an
/// encrypted, forward-secret channel between two destinations with
/// keepalive, request/response and Resource transfer.
///
/// Wire behaviour mirrored from RNS 1.6.1: X25519 ECDH + HKDF-SHA256
/// (64 bytes, salt = link id), AES-256-CBC Token, 3 byte MTU/mode
/// signalling in LINKREQUEST and LRPROOF, link id = truncated hash of the
/// LINKREQUEST hashable part without its signalling bytes.
class Link {
  Link._(this.transport, {required this.initiator});

  // Constants (Link.py:55-110).
  static const int ecPubSize = 64;
  static const int mtuSize = 3;
  static const int keysize = 32;
  static const double keepaliveMaxRtt = 1.75;
  static const int keepaliveTimeoutFactor = 4;
  static const int staleGrace = 5;
  static const int keepaliveMax = 360;
  static const int keepaliveMin = 5;
  static const int staleFactor = 2;
  static const int trafficTimeoutMinMs = 5;
  static const int modeAes256Cbc = 0x01;
  static const int mtuBytemask = 0x1FFFFF;
  static const int modeBytemask = 0xE0;
  static const double watchdogMaxSleep = 5;

  /// Link.MDU for the default MTU (used to size resource hashmaps).
  static const int defaultMdu = 431;

  final Transport transport;
  final bool initiator;

  LinkStatus status = LinkStatus.pending;
  TeardownReason? teardownReason;
  Destination? destination;
  Uint8List linkId = Uint8List(0);
  int mode = modeAes256Cbc;
  int mtu = Packet.mtu;
  int mdu = defaultMdu;
  double? rtt;
  int? expectedHops;
  RnsInterface? attachedInterface;
  double establishmentTimeout = 0;
  double keepalive = keepaliveMax.toDouble();
  double staleTime = (keepaliveMax * staleFactor).toDouble();
  double trafficTimeoutFactor = 6;
  DateTime? activatedAt;
  DateTime requestTime = DateTime.now();
  DateTime lastInbound = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime lastOutbound = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime lastKeepalive = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime lastProof = DateTime.fromMillisecondsSinceEpoch(0);
  int tx = 0;
  int rx = 0;
  int txBytes = 0;
  int rxBytes = 0;

  Identity? _remoteIdentity;

  /// Peer identity once known: the destination identity (initiator) or the
  /// identity the initiator revealed with `identify()` (responder).
  Identity? get remoteIdentity => _remoteIdentity;

  // Key material.
  Uint8List? _prv;
  Uint8List? pubBytes;
  Uint8List? _sigSeed;
  Uint8List? sigPubBytes;
  Uint8List? peerPubBytes;
  Uint8List? peerSigPubBytes;
  Uint8List? _derivedKey;
  Token? _token;

  // Callbacks (LinkCallbacks, Link.py:44).
  void Function(Link)? onEstablished;
  void Function(Link)? onClosed;
  void Function(Uint8List data, Packet packet)? onPacket;
  void Function(Link, Identity)? onRemoteIdentified;
  bool Function(ResourceAdvertisement)? onResourceAdvertised;
  void Function(Resource)? onResourceStarted;
  void Function(Resource)? onResourceConcluded;
  ResourceStrategy resourceStrategy = ResourceStrategy.none;

  final List<Resource> incomingResources = [];
  final List<Resource> outgoingResources = [];
  final List<RequestReceipt> _pending = [];

  Timer? _watchdog;
  final _established = Completer<Link>();
  final _closedC = Completer<Link>();

  /// Completes when the link is active; completes with an error if it closes
  /// first.
  Future<Link> get established => _established.future;

  /// Completes when the link has closed.
  Future<Link> get closed => _closedC.future;

  bool get isActive => status == LinkStatus.active;

  // -------------------------------------------------------------- signalling

  /// Link.signalling_bytes (Link.py:122).
  static Uint8List signallingBytes(int mtu, int mode) {
    if (mode != modeAes256Cbc) {
      throw ArgumentError('Requested link mode $mode not enabled');
    }
    final v = (mtu & mtuBytemask) + (((mode << 5) & modeBytemask) << 16);
    return Uint8List.fromList([(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
  }

  static int _mtuFrom(List<int> b, int o) =>
      ((b[o] << 16) + (b[o + 1] << 8) + b[o + 2]) & mtuBytemask;

  /// Link.update_mdu.
  void updateMdu() {
    mdu =
        ((mtu - 1 - Packet.headerMinSize - Token.tokenOverhead) ~/ 16) * 16 - 1;
  }

  // ------------------------------------------------------------ construction

  /// Starts establishing a link to the outbound SINGLE [destination]
  /// (Link.__init__ + __initiate). Await [established] for the result.
  /// [mtuDiscovery]/next hop interface decide the signalled MTU.
  static Future<Link> initiate(
    Transport transport,
    Destination destination, {
    void Function(Link)? onEstablished,
    void Function(Link)? onClosed,
    RandomBytes? random,
  }) async {
    if (destination.type != DestinationType.single ||
        destination.identity == null) {
      throw ArgumentError('Links can only be established to the "single" '
          'destination type');
    }
    final r = random ?? secureRandomBytes;
    final l = Link._(transport, initiator: true)
      ..destination = destination
      ..onEstablished = onEstablished
      ..onClosed = onClosed;
    l.expectedHops = transport.hopsTo(destination.hash);
    l.establishmentTimeout = transport.firstHopTimeout(destination.hash) +
        transport.config.perHopTimeout.inMilliseconds /
            1000 *
            max(1, l.expectedHops!);
    l._prv = r(32);
    l.pubBytes = await x25519PublicKey(l._prv!);
    l._sigSeed = r(32);
    l.sigPubBytes = await ed25519PublicKey(l._sigSeed!);

    final nh = transport.nextHopInterface(destination.hash);
    final sigMtu =
        (transport.config.linkMtuDiscovery && nh != null && nh.autoconfigureMtu)
            ? nh.hwMtu
            : Packet.mtu;
    final reqData = BytesBuilder(copy: false)
      ..add(l.pubBytes!)
      ..add(l.sigPubBytes!)
      ..add(signallingBytes(sigMtu, modeAes256Cbc));
    final p = Packet(
      destinationHash: destination.hash,
      data: reqData.toBytes(),
      packetType: Packet.typeLinkRequest,
      destinationType: destination.type,
    );
    p.pack();
    l._setLinkId(p);
    l.requestTime = DateTime.now();
    transport.registerPendingLink(l);
    l._startWatchdog();
    final res = await transport.outbound(p);
    if (res.sent) l._hadOutbound();
    return l;
  }

  /// Handles an incoming LINKREQUEST for [owner] (Link.validate_request,
  /// Link.py:154). Returns the new link or null if the request is invalid.
  static Future<Link?> validateRequest(
    Transport transport,
    Destination owner,
    Packet packet,
  ) async {
    final data = packet.data;
    if (data.length != ecPubSize && data.length != ecPubSize + mtuSize) {
      return null;
    }
    try {
      final l = Link._(transport, initiator: false)..destination = owner;
      l.peerPubBytes = Uint8List.fromList(data.sublist(0, 32));
      l.peerSigPubBytes = Uint8List.fromList(data.sublist(32, 64));
      l._setLinkId(packet);

      final iface = packet.receivingInterface;
      if (data.length == ecPubSize + mtuSize) {
        var m = _mtuFrom(data, ecPubSize);
        if (m == 0) m = Packet.mtu;
        final nh = (iface != null && iface.autoconfigureMtu)
            ? iface.hwMtu
            : Packet.mtu;
        l.mtu = nh < m ? nh : m;
      }
      final m = data.length > ecPubSize
          ? (data[ecPubSize] & modeBytemask) >> 5
          : modeAes256Cbc;
      if (m != modeAes256Cbc) return null;
      l.mode = m;
      l.updateMdu();
      l.establishmentTimeout = transport.config.perHopTimeout.inMilliseconds /
              1000 *
              max(1, packet.hops) +
          keepaliveMax;

      // ephemeral X25519 key; signing key is the destination identity's
      final r = secureRandomBytes;
      l._prv = r(32);
      l.pubBytes = await x25519PublicKey(l._prv!);
      final id = owner.identity;
      if (id == null || !id.hasPrivateKey) return null;
      l._sigSeed = id.ed25519Seed;
      l.sigPubBytes = id.ed25519Public;

      await l._handshake();
      l.attachedInterface = iface;
      await l._prove();
      l.requestTime = DateTime.now();
      transport.registerLink(l);
      l.lastInbound = DateTime.now();
      l._startWatchdog();
      return l;
    } on Object {
      return null;
    }
  }

  /// Link id = truncated hash of the LINKREQUEST hashable part without the
  /// trailing signalling bytes (Link.link_id_from_lr_packet, Link.py:420).
  void _setLinkId(Packet p) {
    var hp = p.hashablePart;
    if (p.data.length > ecPubSize) {
      hp =
          Uint8List.sublistView(hp, 0, hp.length - (p.data.length - ecPubSize));
    }
    linkId = truncatedHash(hp);
  }

  /// ECDH + HKDF (Link.handshake, Link.py:432): 64 bytes, salt = link id,
  /// no context.
  Future<void> _handshake() async {
    if (status != LinkStatus.pending || _prv == null) {
      throw StateError('Handshake attempt with invalid state $status');
    }
    status = LinkStatus.handshake;
    final shared = await x25519Exchange(_prv!, peerPubBytes!);
    _derivedKey = hkdf(length: 64, deriveFrom: shared, salt: linkId);
    _token = Token(_derivedKey!);
  }

  /// Responder proof (Link.prove, Link.py:451).
  Future<void> _prove() async {
    final sig = signallingBytes(mtu, mode);
    final signed = [...linkId, ...pubBytes!, ...sigPubBytes!, ...sig];
    final signature = await ed25519Sign(_sigSeed!, signed);
    final proof = Packet(
      destinationHash: linkId,
      data: Uint8List.fromList([...signature, ...pubBytes!, ...sig]),
      packetType: Packet.typeProof,
      context: Packet.lrProof,
      destinationType: DestinationType.link,
      maxSize: mtu,
    );
    final r = await transport.outbound(proof, link: this);
    if (r.sent) _hadOutbound();
  }

  /// Initiator side: validates the LRPROOF (Link.validate_proof,
  /// Link.py:480) and activates the link.
  Future<void> validateProof(Packet packet) async {
    try {
      if (status != LinkStatus.pending) return;
      var data = packet.data;
      final m = data.length > 96 ? data[96] >> 5 : modeAes256Cbc;
      if (m != mode) throw ArgumentError('Invalid link mode $m in proof');
      Uint8List signalling = Uint8List(0);
      int? confirmedMtu;
      if (data.length == 96 + mtuSize) {
        confirmedMtu = _mtuFrom(data, 96);
        signalling = signallingBytes(confirmedMtu, m);
        data = Uint8List.sublistView(data, 0, 96);
      }
      if (!initiator || data.length != 96) return;
      final id = destination!.identity!;
      peerPubBytes = Uint8List.fromList(data.sublist(64, 96));
      peerSigPubBytes = id.ed25519Public;
      await _handshake();
      final signed = [
        ...linkId,
        ...peerPubBytes!,
        ...peerSigPubBytes!,
        ...signalling
      ];
      final signature = data.sublist(0, 64);
      if (!await id.validate(signature, signed)) return; // ignore bad proof
      if (status != LinkStatus.handshake) return;
      rtt = DateTime.now().difference(requestTime).inMicroseconds / 1e6;
      attachedInterface = packet.receivingInterface;
      _remoteIdentity = id;
      mtu = confirmedMtu ?? Packet.mtu;
      updateMdu();
      status = LinkStatus.active;
      activatedAt = DateTime.now();
      lastProof = activatedAt!;
      transport.activateLink(this);
      _updateKeepalive();
      await _sendEncrypted(Packet.lrRtt, packb(rtt));
      if (!_established.isCompleted) _established.complete(this);
      _safe(() => onEstablished?.call(this));
    } on Object {
      // Python: exceptions during proof validation close the link
      status = LinkStatus.closed;
      teardownReason = TeardownReason.timeout;
      _closedCleanup();
    }
  }

  // ----------------------------------------------------------- crypto + send

  Future<Uint8List> encrypt(List<int> plaintext) {
    final t = _token;
    if (t == null) throw StateError('Link has no keys');
    return t.encrypt(plaintext);
  }

  /// Decrypts a link token; null on any failure (Link.decrypt).
  Future<Uint8List?> decrypt(List<int> ciphertext) async {
    final t = _token;
    if (t == null) return null;
    try {
      return await t.decrypt(ciphertext);
    } on Object {
      return null;
    }
  }

  Future<Uint8List> sign(List<int> message) => ed25519Sign(_sigSeed!, message);

  /// Validates a peer signature (Link.validate).
  Future<bool> validate(List<int> signature, List<int> message) async {
    final k = peerSigPubBytes;
    if (k == null) return false;
    return ed25519Verify(k, signature, message);
  }

  void _hadOutbound({bool keepalive = false}) {
    lastOutbound = DateTime.now();
    if (keepalive) lastKeepalive = lastOutbound;
  }

  /// Sends [data] with [context] on this link. [encrypt] false for contexts
  /// Packet.py:pack leaves in clear. Returns the receipt if requested and
  /// applicable.
  Future<PacketReceipt?> sendPacket(
    int context,
    List<int> data, {
    int packetType = Packet.typeData,
    bool encrypted = true,
    bool createReceipt = false,
    Packet? built,
  }) async {
    if (status == LinkStatus.closed) return null;
    final body = encrypted ? await encrypt(data) : Uint8List.fromList(data);
    final p = built ??
        Packet(
          destinationHash: linkId,
          data: body,
          packetType: packetType,
          context: context,
          destinationType: DestinationType.link,
          maxSize: mtu,
        );
    tx += 1;
    txBytes += body.length;
    final r = await transport.outbound(
      p,
      link: this,
      destination: destination,
      createReceipt: createReceipt,
    );
    if (r.sent) _hadOutbound(keepalive: context == Packet.keepalive);
    return r.receipt;
  }

  Future<void> _sendEncrypted(int context, List<int> data) =>
      sendPacket(context, data);

  /// Sends application [data] over the link (DATA, context NONE). The
  /// returned receipt completes when the peer proves the packet.
  Future<PacketReceipt?> send(List<int> data) => sendPacket(
        Packet.noneContext,
        data,
        createReceipt: true,
      );

  /// Reveals [identity] to the peer (Link.identify, Link.py:540); initiator
  /// only. Signature covers `link_id || public_key`.
  Future<void> identify(Identity identity) async {
    if (!initiator || status != LinkStatus.active) return;
    final sig = await identity.sign([...linkId, ...identity.publicKey]);
    await sendPacket(
      Packet.linkIdentify,
      [...identity.publicKey, ...sig],
    );
  }

  /// Sends a request to [path] (Link.request, Link.py:556). Large requests
  /// travel as a Resource. [timeout] seconds defaults to
  /// `rtt * traffic_timeout_factor + RESPONSE_MAX_GRACE_TIME * 1.125`.
  Future<RequestReceipt?> request(
    String path, {
    Object? data,
    double? timeout,
    int? maxResponseSize,
    void Function(RequestReceipt)? onProgress,
  }) async {
    final pathHash = truncatedHash(utf8.encode(path));
    final packed = packb([unixNow(), pathHash, data]);
    final to = timeout ??
        ((rtt ?? 1.0) * trafficTimeoutFactor +
            Resource.responseMaxGraceTime * 1.125);
    if (packed.length <= mdu) {
      final body = await encrypt(packed);
      final p = Packet(
        destinationHash: linkId,
        data: body,
        context: Packet.request,
        destinationType: DestinationType.link,
        maxSize: mtu,
      );
      p.pack();
      final id = p.truncatedPacketHash;
      final rr = RequestReceipt._(
          this, id, to, packed.length, maxResponseSize, onProgress);
      _pending.add(rr);
      await sendPacket(Packet.request, body, encrypted: false, built: p);
      rr._startTimer(to);
      return rr;
    } else {
      final id = truncatedHash(packed);
      final rr = RequestReceipt._(
          this, id, to, packed.length, maxResponseSize, onProgress);
      _pending.add(rr);
      final res = await Resource.send(
        this,
        packed,
        requestId: id,
        isResponse: false,
        timeout: to,
        callback: (r) {
          if (r.status == ResourceStatus.complete) {
            rr.status = RequestStatus.delivered;
            rr._startTimer(to);
          } else {
            rr._fail();
          }
        },
      );
      if (res == null) {
        rr._fail();
      }
      return rr;
    }
  }

  // ----------------------------------------------------------------- receive

  /// Processes a packet addressed to this link (Link.__receive, Link.py:1090).
  Future<void> receive(Packet p) async {
    try {
      await _receive(p);
    } on Object {
      // a failing packet never kills the link
    }
  }

  Future<void> _receive(Packet p) async {
    if (status == LinkStatus.closed) return;
    if (initiator &&
        p.context == Packet.keepalive &&
        p.data.length == 1 &&
        p.data[0] == 0xFF) {
      return;
    }
    if (!identical(p.receivingInterface, attachedInterface)) return;
    lastInbound = DateTime.now();
    rx += 1;
    rxBytes += p.data.length;
    if (status == LinkStatus.stale) status = LinkStatus.active;

    if (p.packetType == Packet.typeData) {
      switch (p.context) {
        case Packet.noneContext:
          final plain = await decrypt(p.data);
          if (plain == null) return;
          _safe(() => onPacket?.call(plain, p));
          final d = destination;
          if (d != null) {
            if (d.proofStrategy == ProofStrategy.all) {
              await provePacket(p);
            } else if (d.proofStrategy == ProofStrategy.app) {
              final cb = d.onProofRequested;
              if (cb != null && cb(p)) await provePacket(p);
            }
          }
        case Packet.linkIdentify:
          final plain = await decrypt(p.data);
          if (plain == null || initiator || plain.length != 128) return;
          final pub = plain.sublist(0, 64);
          final sig = plain.sublist(64, 128);
          final identity = Identity.fromPublicKey(pub);
          if (await identity.validate(sig, [...linkId, ...pub])) {
            if (_remoteIdentity == null) {
              _remoteIdentity = identity;
              _safe(() => onRemoteIdentified?.call(this, identity));
            }
          }
        case Packet.request:
          final packed = await decrypt(p.data);
          if (packed == null) return;
          final max = destination?.maxRequestSize;
          if (max != null && packed.length > max) return;
          final unpacked = unpackb(packed);
          final id = p.truncatedPacketHash;
          unawaited(_handleRequest(id, unpacked));
        case Packet.response:
          final packed = await decrypt(p.data);
          if (packed == null) return;
          final un = unpackb(packed)! as List<Object?>;
          final transfer = packb(un[1]).length - 2;
          _handleResponse(
            un[0]! as Uint8List,
            un[1],
            transfer,
            transfer,
            updateSizes: true,
            checkSize: true,
          );
        case Packet.lrRtt:
          if (!initiator) await _rttPacket(p);
        case Packet.linkClose:
          await _teardownPacket(p);
        case Packet.resourceAdv:
          await _resourceAdv(p);
        case Packet.resourceReq:
          final plain = await decrypt(p.data);
          if (plain == null) return;
          final String hashHex;
          if (plain[0] == Resource.hashmapIsExhausted) {
            hashHex = toHex(plain.sublist(
                1 + Resource.maphashLen, 33 + Resource.maphashLen));
          } else {
            hashHex = toHex(plain.sublist(1, 33));
          }
          for (final r in [...outgoingResources]) {
            if (toHex(r.hash) == hashHex) {
              final ph = toHex(p.packetHash);
              if (!r.reqHashlist.contains(ph)) {
                r.reqHashlist.add(ph);
                await r.request(plain);
              }
            }
          }
        case Packet.resourceHmu:
          final plain = await decrypt(p.data);
          if (plain == null) return;
          final h = toHex(plain.sublist(0, 32));
          for (final r in [...incomingResources]) {
            if (toHex(r.hash) == h) await r.hashmapUpdatePacket(plain);
          }
        case Packet.resourceIcl:
          final plain = await decrypt(p.data);
          if (plain == null) return;
          final h = toHex(plain.sublist(0, 32));
          for (final r in [...incomingResources]) {
            if (toHex(r.hash) == h) await r.cancel();
          }
        case Packet.resourceRcl:
          final plain = await decrypt(p.data);
          if (plain == null) return;
          final h = toHex(plain.sublist(0, 32));
          for (final r in [...outgoingResources]) {
            if (toHex(r.hash) == h) r.rejected();
          }
        case Packet.keepalive:
          if (!initiator && p.data.length == 1 && p.data[0] == 0xFF) {
            final since =
                DateTime.now().difference(lastOutbound).inMicroseconds / 1e6;
            if (since >= keepalive) {
              await sendPacket(
                Packet.keepalive,
                [0xFE],
                encrypted: false,
              );
            }
          }
        case Packet.resource:
          for (final r in [...incomingResources]) {
            await r.receivePart(p);
          }
      }
    } else if (p.packetType == Packet.typeProof) {
      if (p.context == Packet.resourcePrf) {
        final h = toHex(p.data.sublist(0, 32));
        for (final r in [...outgoingResources]) {
          if (toHex(r.hash) == h) await r.validateProof(p.data);
        }
      }
    }
  }

  /// Link.prove_packet: explicit proof `packet_hash || signature` signed with
  /// the link key.
  Future<void> provePacket(Packet p) async {
    final sig = await sign(p.packetHash);
    await sendPacket(
      Packet.noneContext,
      [...p.packetHash, ...sig],
      packetType: Packet.typeProof,
      encrypted: false,
    );
  }

  Future<void> _rttPacket(Packet p) async {
    try {
      final measured =
          DateTime.now().difference(requestTime).inMicroseconds / 1e6;
      final plain = await decrypt(p.data);
      if (plain == null) return;
      final r = (unpackb(plain)! as num).toDouble();
      rtt = max(measured, r);
      status = LinkStatus.active;
      activatedAt = DateTime.now();
      expectedHops = p.hops;
      _updateKeepalive();
      if (!_established.isCompleted) _established.complete(this);
      _safe(() => destination?.onLinkEstablished?.call(this));
      _safe(() => onEstablished?.call(this));
    } on Object {
      await teardown();
    }
  }

  void _updateKeepalive() {
    keepalive = max(
      min(rtt! * (keepaliveMax / keepaliveMaxRtt), keepaliveMax.toDouble()),
      keepaliveMin.toDouble(),
    );
    staleTime = keepalive * staleFactor;
  }

  // --------------------------------------------------------------- requests

  Future<void> _handleRequest(Uint8List requestId, Object? unpacked) async {
    if (status != LinkStatus.active) return;
    try {
      final u = unpacked! as List<Object?>;
      final requestedAt = (u[0]! as num).toDouble();
      final pathHash = u[1]! as Uint8List;
      final data = u[2];
      final handler = destination?.requestHandlers[toHex(pathHash)];
      if (handler == null) return;
      var allowed = false;
      switch (handler.policy) {
        case RequestPolicy.none:
          allowed = false;
        case RequestPolicy.all:
          allowed = true;
        case RequestPolicy.list:
          final ri = _remoteIdentity;
          allowed = ri != null &&
              handler.allowedList.any((h) => constantTimeEquals(h, ri.hash));
      }
      if (!allowed) return;
      final response = await handler.generator(
        handler.path,
        data,
        requestId,
        linkId,
        _remoteIdentity,
        requestedAt,
      );
      if (response == null) return;
      final packed = packb([requestId, response]);
      if (packed.length <= mdu) {
        await sendPacket(Packet.response, packed);
      } else {
        await Resource.send(
          this,
          packed,
          requestId: requestId,
          isResponse: true,
          autoCompress: handler.autoCompress,
        );
      }
    } on Object {
      // handler errors do not affect the link
    }
  }

  void _handleResponse(
    Uint8List requestId,
    Object? response,
    int responseSize,
    int transferSize, {
    Object? metadata,
    bool updateSizes = false,
    bool checkSize = false,
  }) {
    if (status != LinkStatus.active) return;
    RequestReceipt? found;
    for (final r in _pending) {
      if (constantTimeEquals(r.requestId, requestId)) {
        found = r;
        break;
      }
    }
    if (found == null) return;
    _pending.remove(found);
    final sizeOk = !checkSize ||
        found.maxResponseSize == null ||
        responseSize <= found.maxResponseSize!;
    if (updateSizes) {
      found.responseSize = responseSize;
      found.responseTransferSize =
          (found.responseTransferSize ?? 0) + transferSize;
    }
    if (sizeOk) {
      found._ready(response, metadata);
    } else {
      found._fail();
    }
  }

  void _requestResourceConcluded(Resource r) {
    if (r.status != ResourceStatus.complete) return;
    final packed = r.data!;
    final unpacked = unpackb(packed);
    final id = truncatedHash(packed);
    unawaited(_handleRequest(id, unpacked));
  }

  void _responseResourceConcluded(Resource r) {
    if (r.status == ResourceStatus.complete) {
      final un = unpackb(r.data!)! as List<Object?>;
      _handleResponse(un[0]! as Uint8List, un[1], r.totalSize, r.size);
    } else {
      for (final pr in [..._pending]) {
        if (r.requestId != null &&
            constantTimeEquals(pr.requestId, r.requestId!)) {
          pr._fail();
        }
      }
    }
  }

  Future<void> _resourceAdv(Packet p) async {
    final plain = await decrypt(p.data);
    if (plain == null) return;
    try {
      final adv = ResourceAdvertisement.unpack(plain);
      if (adv.isRequest) {
        if (destination != null && destination!.requestHandlers.isNotEmpty) {
          final max = destination!.maxRequestSize;
          if (max == null || adv.dataSize <= max) {
            await Resource.accept(this, adv,
                callback: _requestResourceConcluded);
          } else {
            await Resource.reject(this, adv);
          }
        }
      } else if (adv.isResponse) {
        for (final pr in _pending) {
          if (adv.requestId != null &&
              constantTimeEquals(pr.requestId, adv.requestId!)) {
            if (pr.maxResponseSize != null &&
                adv.dataSize > pr.maxResponseSize!) {
              await Resource.reject(this, adv);
              pr._fail();
            } else {
              final res = await Resource.accept(
                this,
                adv,
                callback: _responseResourceConcluded,
                progressCallback: pr._resourceProgress,
                requestId: adv.requestId,
              );
              if (res != null) {
                pr.responseSize ??= adv.dataSize;
                pr.responseTransferSize =
                    (pr.responseTransferSize ?? 0) + adv.transferSize;
                pr._resourceProgress(res);
              }
            }
            break;
          }
        }
      } else if (resourceStrategy == ResourceStrategy.all) {
        await Resource.accept(this, adv, callback: _resourceDone);
      } else if (resourceStrategy == ResourceStrategy.app) {
        final cb = onResourceAdvertised;
        if (cb != null && cb(adv)) {
          await Resource.accept(this, adv, callback: _resourceDone);
        } else {
          await Resource.reject(this, adv);
        }
      }
    } on Object {
      await teardown();
    }
  }

  void _resourceDone(Resource r) => _safe(() => onResourceConcluded?.call(r));

  /// Sends [data] as a Resource (bz2-compressed when beneficial). Returns
  /// null if the link is not usable.
  Future<Resource?> sendResource(
    Uint8List data, {
    void Function(Resource)? callback,
    void Function(Resource)? progressCallback,
    bool autoCompress = true,
  }) =>
      Resource.send(
        this,
        data,
        callback: callback,
        progressCallback: progressCallback,
        autoCompress: autoCompress,
      );

  // ----------------------------------------------------------------- resource

  void resourceConcluded(Resource r) {
    incomingResources.remove(r);
    outgoingResources.remove(r);
  }

  bool get readyForNewResource => outgoingResources.isEmpty;

  // ---------------------------------------------------------------- teardown

  Future<void> _teardownPacket(Packet p) async {
    final plain = await decrypt(p.data);
    if (plain != null && constantTimeEquals(plain, linkId)) {
      status = LinkStatus.closed;
      teardownReason = initiator
          ? TeardownReason.destinationClosed
          : TeardownReason.initiatorClosed;
      _closedCleanup();
    }
  }

  /// Closes the link, notifying the peer (Link.teardown, Link.py:633).
  Future<void> teardown() async {
    if (status == LinkStatus.closed) return;
    final wasPending = status == LinkStatus.pending;
    if (!wasPending) {
      try {
        await sendPacket(Packet.linkClose, linkId);
      } on Object {
        // best effort
      }
    }
    status = LinkStatus.closed;
    teardownReason = initiator
        ? TeardownReason.initiatorClosed
        : TeardownReason.destinationClosed;
    _closedCleanup();
  }

  void _closedCleanup() {
    _watchdog?.cancel();
    for (final r in [...incomingResources]) {
      unawaited(r.cancel());
    }
    for (final r in [...outgoingResources]) {
      unawaited(r.cancel());
    }
    for (final pr in [..._pending]) {
      pr._fail();
    }
    _prv = null;
    _derivedKey = null;
    _token = null;
    transport.unregisterLink(this);
    destination?.links.remove(this);
    if (!_established.isCompleted) {
      _established.completeError(
        StateError('Link closed before establishment: $teardownReason'),
      );
      // avoid unhandled error if nobody awaits `established`
      unawaited(_established.future.then<void>((_) {}, onError: (Object _) {}));
    }
    _safe(() => onClosed?.call(this));
    if (!_closedC.isCompleted) _closedC.complete(this);
  }

  // ---------------------------------------------------------------- watchdog

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(milliseconds: 100), _tick);
  }

  double _secondsSince(DateTime t) =>
      DateTime.now().difference(t).inMicroseconds / 1e6;

  /// Link.__watchdog_job (Link.py:710), one iteration.
  Future<void> _tick() async {
    if (status == LinkStatus.closed) return;
    double sleep = 0.1;
    switch (status) {
      case LinkStatus.pending:
      case LinkStatus.handshake:
        final next = establishmentTimeout - _secondsSince(requestTime);
        if (next <= 0) {
          status = LinkStatus.closed;
          teardownReason = TeardownReason.timeout;
          _closedCleanup();
          return;
        }
        sleep = next;
      case LinkStatus.active:
        final activated = activatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        var li = lastInbound;
        if (lastProof.isAfter(li)) li = lastProof;
        if (activated.isAfter(li)) li = activated;
        final sinceIn = _secondsSince(li);
        final sinceOut = _secondsSince(lastOutbound);
        if (sinceIn >= keepalive || sinceOut >= keepalive) {
          if (initiator && _secondsSince(lastKeepalive) >= keepalive) {
            await sendPacket(Packet.keepalive, [0xFF], encrypted: false);
          }
          if (sinceIn >= staleTime) {
            sleep = (rtt ?? 1) * keepaliveTimeoutFactor + staleGrace;
            status = LinkStatus.stale;
          } else {
            sleep = keepalive;
          }
        } else {
          sleep = keepalive - sinceIn;
        }
      case LinkStatus.stale:
        try {
          await sendPacket(Packet.linkClose, linkId);
        } on Object {
          // ignore
        }
        status = LinkStatus.closed;
        teardownReason = TeardownReason.timeout;
        _closedCleanup();
        return;
      case LinkStatus.closed:
        return;
    }
    if (sleep < 0.001) sleep = 0.001;
    if (sleep > watchdogMaxSleep) sleep = watchdogMaxSleep;
    _watchdog = Timer(Duration(microseconds: (sleep * 1e6).round()), _tick);
  }

  void _safe(void Function() f) {
    try {
      f();
    } on Object {
      // application callbacks must not break link processing
    }
  }

  @override
  String toString() => '<Link ${toHex(linkId)}>';
}
