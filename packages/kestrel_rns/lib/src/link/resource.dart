import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../crypto/hashes.dart';
import '../crypto/random.dart';
import '../msgpack/msgpack.dart';
import '../packet.dart';
import '../util.dart';
import 'link.dart';

/// Resource state (Resource.NONE..REJECTED, Resource.py:143-152). The
/// declaration order matters: states before [assembling] are "in flight".
enum ResourceStatus {
  none,
  queued,
  advertised,
  transferring,
  awaitingProof,
  assembling,
  complete,
  failed,
  corrupt,
  rejected,
}

/// Resource advertisement (ResourceAdvertisement, Resource.py:1130).
///
/// Packed as a msgpack map with keys `t d n h r o i l q f m` in this order.
class ResourceAdvertisement {
  ResourceAdvertisement({
    required this.transferSize,
    required this.dataSize,
    required this.parts,
    required this.hash,
    required this.randomHash,
    required this.originalHash,
    required this.hashmap,
    required this.flags,
    this.segmentIndex = 1,
    this.totalSegments = 1,
    this.requestId,
  });

  /// ResourceAdvertisement.OVERHEAD / HASHMAP_MAX_LEN / COLLISION_GUARD_SIZE
  /// (Resource.py:1132-1135); derived from the *default* Link.MDU.
  static const int overhead = 134;
  static const int hashmapMaxLen = (Link.defaultMdu - overhead) ~/ 4; // 74
  static const int collisionGuardSize = 2 * Resource.windowMax + hashmapMaxLen;

  /// `t`: transfer size (encrypted, possibly compressed stream length).
  final int transferSize;

  /// `d`: total uncompressed data size (incl. metadata).
  final int dataSize;

  /// `n`: number of parts.
  final int parts;
  final Uint8List hash;
  final Uint8List randomHash;
  final Uint8List originalHash;

  /// `m`: hashmap segment 0 (4 bytes per part).
  final Uint8List hashmap;

  /// `f`: flags `a<<6 | x<<5 | p<<4 | u<<3 | s<<2 | c<<1 | e`.
  final int flags;
  final int segmentIndex;
  final int totalSegments;
  final Uint8List? requestId;

  bool get encrypted => flags & 0x01 != 0;
  bool get compressed => (flags >> 1) & 0x01 != 0;
  bool get split => (flags >> 2) & 0x01 != 0;
  bool get isRequestFlag => (flags >> 3) & 0x01 != 0;
  bool get isResponseFlag => (flags >> 4) & 0x01 != 0;
  bool get hasMetadata => (flags >> 5) & 0x01 != 0;
  bool get appFlag => (flags >> 6) & 0x01 != 0;
  bool get isRequest => requestId != null && isRequestFlag;
  bool get isResponse => requestId != null && isResponseFlag;

  /// Packs segment [segment] of the hashmap; drops the hashmap if the result
  /// would exceed [mdu] (Resource.py:1196).
  Uint8List pack({int segment = 0, required int mdu}) {
    final start = segment * hashmapMaxLen;
    final end = min((segment + 1) * hashmapMaxLen, parts);
    Uint8List m = Uint8List.sublistView(hashmap, start * 4, end * 4);
    Uint8List build(Uint8List map) => packb({
          't': transferSize,
          'd': dataSize,
          'n': parts,
          'h': hash,
          'r': randomHash,
          'o': originalHash,
          'i': segmentIndex,
          'l': totalSegments,
          'q': requestId,
          'f': flags,
          'm': map,
        });
    var packed = build(m);
    if (packed.length > mdu) {
      m = Uint8List(0);
      packed = build(m);
    }
    return packed;
  }

  /// Parses an advertisement (ResourceAdvertisement.unpack, Resource.py:1217).
  static ResourceAdvertisement unpack(List<int> data) {
    final d = unpackb(data)! as Map<Object?, Object?>;
    final t = d['t']! as int;
    if (t > Resource.maxEfficientSize * 3) {
      throw ArgumentError('Invalid transfer size');
    }
    return ResourceAdvertisement(
      transferSize: t,
      dataSize: d['d']! as int,
      parts: d['n']! as int,
      hash: d['h']! as Uint8List,
      randomHash: d['r']! as Uint8List,
      originalHash: d['o']! as Uint8List,
      hashmap: d['m']! as Uint8List,
      flags: d['f']! as int,
      segmentIndex: d['i']! as int,
      totalSegments: d['l']! as int,
      requestId: d['q'] as Uint8List?,
    );
  }
}

/// Segments of a multi-segment resource received so far (in memory).
class SplitBuffer {
  final BytesBuilder _data = BytesBuilder(copy: false);
  Object? metadata;
  int _received = 0;

  /// Index of the segment expected next (1-based).
  int get next => _received + 1;

  void add(Uint8List segment, Object? meta) {
    _data.add(Uint8List.fromList(segment));
    if (_received == 0) metadata = meta;
    _received++;
  }

  Uint8List take() => _data.takeBytes();
}

/// Arbitrary-size reliable transfer over a [Link] (RNS/Resource.py):
/// sequencing, optional bz2 compression, link encryption, a hashmap of
/// 4-byte part hashes, windowed part requests and a final proof.
///
/// Supported: single-segment resources (up to [maxEfficientSize], ~1 MiB) in
/// both directions, requests/responses as resources, metadata on receive and
/// multi-segment (split) resources on RECEIVE (RNS 1.x: a large file arrives
/// as consecutive ~1 MiB segments that are concatenated in memory, up to
/// `TransportConfig.maxResourceSize`).
/// Not supported: sending multi-segment resources, sending metadata, file
/// handles.
class Resource {
  Resource._(this.link);

  // Constants (Resource.py:57-135).
  static const int window = 4;
  static const int windowMin = 2;
  static const int windowMaxSlow = 10;
  static const int windowMaxVerySlow = 4;
  static const int windowMaxFast = 75;
  static const int windowMax = windowMaxFast;
  static const int fastRateThreshold = windowMaxSlow - window - 2;
  static const int veryFastRateThreshold = 2;
  static const double rateFast = (50 * 1000) / 8;
  static const double rateVerySlow = (2 * 1000) / 8;
  static const int windowFlexibility = 4;
  static const int maphashLen = 4;
  static const int randomHashSize = 4;
  static const int maxEfficientSize = 1 * 1024 * 1024 - 1;
  static const double responseMaxGraceTime = 10;
  static const int autoCompressMaxSize = 64 * 1024 * 1024;
  static const double partTimeoutFactor = 4;
  static const double partTimeoutFactorAfterRtt = 2;
  static const double proofTimeoutFactor = 3;
  static const double hmuWaitFactor = 3.5;
  static const int maxRetries = 16;
  static const int maxAdvRetries = 4;
  static const double senderGraceTime = 10.0;
  static const double processingGrace = 1.0;
  static const double retryGraceTime = 0.25;
  static const double perRetryDelay = 0.5;

  static const int hashmapIsNotExhausted = 0x00;
  static const int hashmapIsExhausted = 0xFF;
  static const int hashmapIsEmpty = 0xFE;

  final Link link;
  ResourceStatus status = ResourceStatus.none;
  bool initiator = false;

  late Uint8List hash;
  late Uint8List randomHash;
  late Uint8List originalHash;
  Uint8List? requestId;
  bool isResponse = false;
  bool compressed = false;
  bool encrypted = true;
  bool hasMetadata = false;
  bool split = false;

  /// Segment of a multi-segment resource (1-based) and the segment count.
  int segmentIndex = 1;
  int totalSegments = 1;

  /// Transfer size (encrypted stream) and total data size.
  int size = 0;
  int totalSize = 0;
  int totalParts = 0;
  int sdu = 0;

  void Function(Resource)? callback;
  void Function(Resource)? progressCallback;

  /// Received data (receiver, once [status] is complete) with metadata
  /// stripped; [metadata] holds the unpacked metadata if any.
  Uint8List? data;
  Object? metadata;

  // --- sender state ---
  late Uint8List _expectedProof;
  List<Uint8List> _parts = [];
  List<Uint8List> _mapHashes = [];
  List<bool> _partSent = [];
  Uint8List _hashmapBytes = Uint8List(0);
  int sentParts = 0;
  final List<String> reqHashlist = [];
  int _receiverMinConsecutiveHeight = 0;
  DateTime _advSent = DateTime.now();
  DateTime _lastPartSent = DateTime.now();
  int _retriesLeft = maxRetries;
  double _timeout = 0;
  double _timeoutFactor = 6;
  Uint8List? _advPlain;

  // --- receiver state ---
  List<Uint8List?> _rparts = [];
  List<Uint8List?> _hashmap = [];
  int _hashmapHeight = 0;
  int receivedCount = 0;
  int _outstanding = 0;
  int _window = Resource.window;
  int _windowMax = windowMaxSlow;
  int _windowMin = windowMin;
  final int _windowFlex = windowFlexibility;
  int _consecutiveCompleted = -1;
  bool _waitingForHmu = false;
  bool _assembling = false;
  DateTime _lastActivity = DateTime.now();
  DateTime? _reqSent;
  int _reqSentBytes = 0;
  bool _reqResp = true;
  double? _rtt;
  double _reqRespRttRate = 0;
  double _reqDataRttRate = 0;
  int _rttRxdBytes = 0;
  int _rttRxdBytesAtReq = 0;
  int _fastRounds = 0;
  int _verySlowRounds = 0;
  double? _eifr;
  int _maxSize = 0;
  Timer? _watchdog;
  int _watchdogId = 0;

  /// Progress in `[0, 1]`.
  double get progress {
    if (status == ResourceStatus.complete) return 1.0;
    if (totalParts == 0) return 0;
    final done = initiator ? sentParts : receivedCount;
    return min(1.0, done / totalParts);
  }

  /// Hash of the whole resource.
  Uint8List get resourceHash => hash;

  // ============================================================== sending

  /// Creates and advertises a resource carrying [data] over [link]
  /// (Resource.__init__ + advertise). Returns null if the link is unusable or
  /// the data exceeds [maxEfficientSize]. [callback] fires when the transfer
  /// concludes (check [status]).
  static Future<Resource?> send(
    Link link,
    Uint8List data, {
    Uint8List? requestId,
    bool isResponse = false,
    bool autoCompress = true,
    double? timeout,
    void Function(Resource)? callback,
    void Function(Resource)? progressCallback,
    RandomBytes? random,
  }) async {
    if (link.status != LinkStatus.active) return null;
    if (data.length > maxEfficientSize) return null;
    final r = random ?? secureRandomBytes;
    final res = Resource._(link)
      ..initiator = true
      ..requestId = requestId
      ..isResponse = isResponse
      ..callback = callback
      ..progressCallback = progressCallback;
    res.sdu = link.mtu - Packet.headerMaxSize - Packet.ifacMinSize;
    res._timeout = timeout ?? (link.rtt ?? 1.0) * link.trafficTimeoutFactor;
    res._timeoutFactor = link.trafficTimeoutFactor;
    res.totalSize = data.length;

    Uint8List body = data;
    if (autoCompress && data.length <= autoCompressMaxSize) {
      try {
        final c = BZip2Encoder().encodeBytes(data);
        if (c.length < data.length) {
          body = c;
          res.compressed = true;
        }
      } on Object {
        // fall back to uncompressed
      }
    }
    final stream = Uint8List.fromList([...r(randomHashSize), ...body]);
    final enc = await link.encrypt(stream);
    res.size = enc.length;
    res.totalParts = (res.size + res.sdu - 1) ~/ res.sdu;

    // Hashmap with collision guard (Resource.py:360-395).
    var ok = false;
    while (!ok) {
      res.randomHash = r(randomHashSize);
      res.hash = sha256([...data, ...res.randomHash]);
      res._expectedProof = sha256([...data, ...res.hash]);
      res.originalHash = res.hash;
      res._parts = [];
      res._mapHashes = [];
      final guard = <String>[];
      final mh = BytesBuilder(copy: false);
      ok = true;
      for (var i = 0; i < res.totalParts; i++) {
        final part = Uint8List.sublistView(
          enc,
          i * res.sdu,
          min((i + 1) * res.sdu, enc.length),
        );
        final m = Uint8List.sublistView(
          sha256([...part, ...res.randomHash]),
          0,
          maphashLen,
        );
        final mk = toHex(m);
        if (guard.contains(mk)) {
          ok = false;
          break;
        }
        guard.add(mk);
        if (guard.length > ResourceAdvertisement.collisionGuardSize) {
          guard.removeAt(0);
        }
        res._parts.add(Uint8List.fromList(part));
        res._mapHashes.add(m);
        mh.add(m);
      }
      res._hashmapBytes = mh.toBytes();
    }
    res._partSent = List<bool>.filled(res.totalParts, false);
    unawaited(res._advertise());
    return res;
  }

  ResourceAdvertisement _adv() {
    final flags = (0 << 6) |
        ((hasMetadata ? 1 : 0) << 5) |
        ((requestId != null && isResponse ? 1 : 0) << 4) |
        ((requestId != null && !isResponse ? 1 : 0) << 3) |
        ((split ? 1 : 0) << 2) |
        ((compressed ? 1 : 0) << 1) |
        1;
    return ResourceAdvertisement(
      transferSize: size,
      dataSize: totalSize,
      parts: totalParts,
      hash: hash,
      randomHash: randomHash,
      originalHash: originalHash,
      hashmap: _hashmapBytes,
      flags: flags,
      requestId: requestId,
    );
  }

  Future<void> _advertise() async {
    _advPlain = _adv().pack(mdu: link.mdu);
    while (!link.readyForNewResource) {
      status = ResourceStatus.queued;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (link.status != LinkStatus.active) {
        await cancel();
        return;
      }
    }
    if (link.status != LinkStatus.active) {
      await cancel();
      return;
    }
    try {
      link.outgoingResources.add(this);
      await link.sendPacket(Packet.resourceAdv, _advPlain!);
      _lastActivity = DateTime.now();
      _advSent = _lastActivity;
      _rtt = null;
      status = ResourceStatus.advertised;
      _retriesLeft = maxAdvRetries;
    } on Object {
      await cancel();
      return;
    }
    _startWatchdog();
  }

  /// Sender: handles a RESOURCE_REQ (Resource.request, Resource.py:1010).
  Future<void> request(Uint8List req) async {
    if (status == ResourceStatus.failed) return;
    final rtt = _since(_advSent);
    _rtt ??= rtt;
    if (status != ResourceStatus.transferring) {
      status = ResourceStatus.transferring;
      _startWatchdog();
    }
    _retriesLeft = maxRetries;

    var pad = 1;
    var hashmapEmpty = false;
    var wantsMore = false;
    if (req[0] == hashmapIsEmpty) {
      wantsMore = true;
      hashmapEmpty = true;
    }
    if (req[0] == hashmapIsExhausted) {
      wantsMore = true;
      pad += maphashLen;
    }
    final requested = req.sublist(pad + 32);
    final wanted = <String>{};
    for (var i = 0; i < requested.length ~/ maphashLen; i++) {
      wanted
          .add(toHex(requested.sublist(i * maphashLen, (i + 1) * maphashLen)));
    }
    final searchStart = _receiverMinConsecutiveHeight;
    final searchEnd = min(
      _receiverMinConsecutiveHeight + ResourceAdvertisement.collisionGuardSize,
      _parts.length,
    );
    for (var i = searchStart; i < searchEnd; i++) {
      if (!wanted.contains(toHex(_mapHashes[i]))) continue;
      try {
        if (link.status != LinkStatus.active) {
          await cancel();
          return;
        }
        await link.sendPacket(Packet.resource, _parts[i], encrypted: false);
        if (!_partSent[i]) {
          _partSent[i] = true;
          sentParts += 1;
        }
        _lastActivity = DateTime.now();
        _lastPartSent = _lastActivity;
      } on Object {
        await cancel();
        return;
      }
    }

    if (wantsMore) {
      final lastMapHash = req.sublist(1, 1 + maphashLen);
      var partIndex = _receiverMinConsecutiveHeight;
      final ss = hashmapEmpty ? 0 : partIndex;
      final se = hashmapEmpty
          ? 0
          : min(
              _receiverMinConsecutiveHeight +
                  ResourceAdvertisement.collisionGuardSize,
              _parts.length,
            );
      for (var i = ss; i < se; i++) {
        partIndex += 1;
        if (toHex(_mapHashes[i]) == toHex(lastMapHash)) break;
      }
      _receiverMinConsecutiveHeight = max(partIndex - 1 - windowMax, 0);
      if (!hashmapEmpty &&
          partIndex % ResourceAdvertisement.hashmapMaxLen != 0) {
        await cancel();
        return;
      }
      final segment = partIndex ~/ ResourceAdvertisement.hashmapMaxLen;
      final hs = segment * ResourceAdvertisement.hashmapMaxLen;
      final he = min(
          (segment + 1) * ResourceAdvertisement.hashmapMaxLen, _parts.length);
      final hm = _hashmapBytes.sublist(hs * maphashLen, he * maphashLen);
      if (hm.isEmpty) {
        await cancel();
        return;
      }
      await link.sendPacket(
        Packet.resourceHmu,
        [
          ...hash,
          ...packb([segment, hm])
        ],
      );
      _lastActivity = DateTime.now();
    }

    if (sentParts == _parts.length) {
      status = ResourceStatus.awaitingProof;
      _retriesLeft = 3;
    }
    progressCallback?.call(this);
  }

  /// Sender: validates the receiver's proof (Resource.validate_proof).
  Future<void> validateProof(Uint8List proof) async {
    if (status == ResourceStatus.failed) return;
    if (proof.length != 64) return;
    if (!constantTimeEquals(proof.sublist(32), _expectedProof)) return;
    status = ResourceStatus.complete;
    _watchdog?.cancel();
    link.resourceConcluded(this);
    callback?.call(this);
  }

  /// Sender: the peer refused the advertisement (RESOURCE_RCL).
  void rejected() {
    if (status.index < ResourceStatus.complete.index && initiator) {
      status = ResourceStatus.rejected;
      _watchdog?.cancel();
      link.resourceConcluded(this);
      callback?.call(this);
    }
  }

  // ============================================================ receiving

  /// Rejects an advertisement (Resource.reject).
  static Future<void> reject(Link link, ResourceAdvertisement adv) async {
    await link.sendPacket(Packet.resourceRcl, adv.hash);
  }

  /// Accepts [adv] and starts requesting parts (Resource.accept,
  /// Resource.py:155). Returns null if rejected or already transferring.
  static Future<Resource?> accept(
    Link link,
    ResourceAdvertisement adv, {
    void Function(Resource)? callback,
    void Function(Resource)? progressCallback,
    Uint8List? requestId,
  }) async {
    final maxSize = link.transport.config.maxResourceSize;
    if (adv.dataSize > maxSize ||
        adv.transferSize > maxEfficientSize + 1024 + adv.parts * 64 ||
        adv.totalSegments < 1 ||
        adv.totalSegments > maxSize ~/ (maxEfficientSize ~/ 2) + 2 ||
        adv.segmentIndex < 1 ||
        adv.segmentIndex > adv.totalSegments) {
      await reject(link, adv);
      return null;
    }
    if (adv.totalSegments > 1) {
      // Segments must arrive in order, each continuing the previous one.
      final held = link.splitBuffers[toHex(adv.originalHash)];
      if (adv.segmentIndex == 1) {
        link.splitBuffers[toHex(adv.originalHash)] = SplitBuffer();
      } else if (held == null || held.next != adv.segmentIndex) {
        await reject(link, adv);
        return null;
      }
    }
    final res = Resource._(link)
      ..status = ResourceStatus.transferring
      ..initiator = false
      ..callback = callback
      ..progressCallback = progressCallback
      ..requestId = requestId;
    res.size = adv.transferSize;
    res.totalSize = adv.dataSize;
    res.hash = adv.hash;
    res.originalHash = adv.originalHash;
    res.randomHash = adv.randomHash;
    res.encrypted = adv.encrypted;
    res.compressed = adv.compressed;
    res.hasMetadata = adv.hasMetadata;
    res.split = adv.totalSegments > 1;
    res.segmentIndex = adv.segmentIndex;
    res.totalSegments = adv.totalSegments;
    res._maxSize = maxSize;
    res.sdu = link.mtu - Packet.headerMaxSize - Packet.ifacMinSize;
    res.totalParts = (res.size + res.sdu - 1) ~/ res.sdu;
    if (res.totalParts != adv.parts || res.totalParts < 1) {
      await reject(link, adv);
      return null;
    }
    res._rparts = List<Uint8List?>.filled(res.totalParts, null);
    res._hashmap = List<Uint8List?>.filled(res.totalParts, null);
    res._lastActivity = DateTime.now();
    res._advPlain = null;

    for (final r in link.incomingResources) {
      if (constantTimeEquals(r.hash, res.hash)) return null; // already
    }
    link.incomingResources.add(res);
    try {
      link.onResourceStarted?.call(res);
    } on Object {
      // ignore app callback errors
    }
    await res._hashmapUpdate(0, adv.hashmap);
    res._startWatchdog();
    return res;
  }

  Future<void> hashmapUpdatePacket(Uint8List plaintext) async {
    if (status == ResourceStatus.failed || !_waitingForHmu) return;
    _lastActivity = DateTime.now();
    _retriesLeft = maxRetries;
    final upd = unpackb(plaintext.sublist(32))! as List<Object?>;
    await _hashmapUpdate(upd[0]! as int, upd[1]! as Uint8List);
  }

  Future<void> _hashmapUpdate(int segment, Uint8List map) async {
    if (status == ResourceStatus.failed) return;
    status = ResourceStatus.transferring;
    final segLen = ResourceAdvertisement.hashmapMaxLen;
    final hashes = map.length ~/ maphashLen;
    for (var i = 0; i < hashes; i++) {
      final idx = i + segment * segLen;
      if (idx >= _hashmap.length) break;
      if (_hashmap[idx] == null) _hashmapHeight += 1;
      _hashmap[idx] = Uint8List.fromList(
        map.sublist(i * maphashLen, (i + 1) * maphashLen),
      );
    }
    if (hashes < 1 && segment != 0) {
      await cancel();
    } else {
      _waitingForHmu = false;
      await _requestNext();
    }
  }

  Uint8List _mapHash(List<int> part) =>
      Uint8List.sublistView(sha256([...part, ...randomHash]), 0, maphashLen);

  /// Receiver: process a RESOURCE part (Resource.receive_part).
  Future<void> receivePart(Packet p) async {
    if (status == ResourceStatus.failed || _assembling) return;
    _lastActivity = DateTime.now();
    _retriesLeft = maxRetries;
    if (!_reqResp) {
      _reqResp = true;
      final rtt = _since(_reqSent!);
      _windowMaxFor(rtt);
      final base = link.rtt ?? rtt;
      if (_rtt == null) {
        _rtt = base;
      } else if (rtt < _rtt!) {
        _rtt = max(_rtt! - _rtt! * 0.05, rtt);
      } else if (rtt > _rtt!) {
        _rtt = min(_rtt! + _rtt! * 0.05, rtt);
      }
      if (rtt > 0) {
        final cost = (p.raw?.length ?? p.data.length) + _reqSentBytes;
        _reqRespRttRate = cost / rtt;
        if (_reqRespRttRate > rateFast && _fastRounds < fastRateThreshold) {
          _fastRounds += 1;
          if (_fastRounds == fastRateThreshold) _windowMax = windowMaxFast;
        }
      }
    }
    status = ResourceStatus.transferring;
    final partData = p.data;
    final partHash = toHex(_mapHash(partData));
    final searchStart = _consecutiveCompleted + 1;
    var i = searchStart;
    final end = min(searchStart + _window, _hashmap.length);
    for (var k = searchStart; k < end; k++, i++) {
      final mh = _hashmap[k];
      if (mh != null && toHex(mh) == partHash && _rparts[i] == null) {
        _rparts[i] = Uint8List.fromList(partData);
        _rttRxdBytes += partData.length;
        receivedCount += 1;
        _outstanding -= 1;
        var cp = _consecutiveCompleted + 1;
        while (cp < _rparts.length && _rparts[cp] != null) {
          _consecutiveCompleted = cp;
          cp++;
        }
        progressCallback?.call(this);
      }
    }
    if (receivedCount == totalParts && !_assembling) {
      _assembling = true;
      await _assemble();
    } else if (_outstanding == 0) {
      if (_window < _windowMax) {
        _window += 1;
        if (_window - _windowMin > _windowFlex - 1) _windowMin += 1;
      }
      if (_reqSent != null) {
        final rtt = _since(_reqSent!);
        final transferred = _rttRxdBytes - _rttRxdBytesAtReq;
        if (rtt != 0) {
          _reqDataRttRate = transferred / rtt;
          _updateEifr();
          _rttRxdBytesAtReq = _rttRxdBytes;
          if (_reqDataRttRate > rateFast && _fastRounds < fastRateThreshold) {
            _fastRounds += 1;
            if (_fastRounds == fastRateThreshold) _windowMax = windowMaxFast;
          }
          if (_fastRounds == 0 &&
              _reqDataRttRate < rateVerySlow &&
              _verySlowRounds < veryFastRateThreshold) {
            _verySlowRounds += 1;
            if (_verySlowRounds == veryFastRateThreshold) {
              _windowMax = windowMaxVerySlow;
            }
          }
        }
      }
      await _requestNext();
    }
  }

  void _windowMaxFor(double rtt) {}

  void _updateEifr() {
    final rtt = max(_rtt ?? link.rtt ?? 1.0, 0.001);
    final rate = _reqDataRttRate != 0
        ? _reqDataRttRate * 8
        : (300 * 8) / rtt; // establishment cost estimate
    _eifr = rate;
  }

  /// Receiver: request the next window of parts (Resource.request_next).
  Future<void> _requestNext() async {
    if (status == ResourceStatus.failed || _waitingForHmu) return;
    _outstanding = 0;
    var exhausted = hashmapIsNotExhausted;
    final requested = BytesBuilder(copy: false);
    if (_hashmap[0] == null) {
      exhausted = hashmapIsEmpty;
    } else {
      var i = 0;
      var pn = _consecutiveCompleted + 1;
      final searchStart = pn;
      final end = min(searchStart + _window, _rparts.length);
      for (var k = searchStart; k < end; k++) {
        if (_rparts[k] == null) {
          final ph = _hashmap[pn];
          if (ph != null) {
            requested.add(ph);
            _outstanding += 1;
            i += 1;
          } else {
            exhausted = hashmapIsExhausted;
          }
        }
        pn += 1;
        if (i >= _window || exhausted == hashmapIsExhausted) break;
      }
    }
    final req = BytesBuilder(copy: false)..addByte(exhausted);
    if (exhausted == hashmapIsExhausted) {
      req.add(_hashmap[_hashmapHeight - 1]!);
      _waitingForHmu = true;
    }
    if (exhausted == hashmapIsEmpty) _waitingForHmu = true;
    req
      ..add(hash)
      ..add(requested.toBytes());
    final body = req.toBytes();
    if (link.status != LinkStatus.active) {
      await cancel();
      return;
    }
    _lastActivity = DateTime.now();
    _reqSent = _lastActivity;
    _reqSentBytes = body.length + 50;
    _rttRxdBytesAtReq = _rttRxdBytes;
    _reqResp = false;
    await link.sendPacket(Packet.resourceReq, body);
  }

  Future<void> _assemble() async {
    if (status == ResourceStatus.failed) return;
    try {
      status = ResourceStatus.assembling;
      final stream = BytesBuilder(copy: false);
      for (final p in _rparts) {
        stream.add(p!);
      }
      final Uint8List? plain =
          encrypted ? await link.decrypt(stream.toBytes()) : stream.toBytes();
      if (plain == null) throw StateError('decrypt failed');
      var body = Uint8List.sublistView(plain, randomHashSize);
      if (compressed) {
        body = BZip2Decoder().decodeBytes(
          body,
          verify: true,
          throwOnError: true,
          maxOutputSize: max(_maxSize, totalSize) + 1,
        );
      }
      final calc = sha256([...body, ...randomHash]);
      if (!constantTimeEquals(calc, hash)) {
        status = ResourceStatus.corrupt;
      } else {
        var out = body;
        // metadata only prefixes the first segment (Resource.py:713)
        if (hasMetadata && segmentIndex == 1) {
          final ml = (body[0] << 16) | (body[1] << 8) | body[2];
          metadata = unpackb(body.sublist(3, 3 + ml));
          out = Uint8List.sublistView(body, 3 + ml);
        }
        if (totalSegments > 1) {
          final buf = link.splitBuffers[toHex(originalHash)];
          if (buf == null || buf.next != segmentIndex) {
            throw StateError('segment out of order');
          }
          buf.add(out, metadata);
          if (segmentIndex == totalSegments) {
            link.splitBuffers.remove(toHex(originalHash));
            data = buf.take();
            metadata = buf.metadata;
          }
        } else {
          data = Uint8List.fromList(out);
        }
        status = ResourceStatus.complete;
        // proof = SHA256(data_with_metadata || resource_hash)
        final proof = sha256([...body, ...hash]);
        if (link.status == LinkStatus.active) {
          await link.sendPacket(
            Packet.resourcePrf,
            [...hash, ...proof],
            packetType: Packet.typeProof,
            encrypted: false,
          );
        }
      }
    } on Object {
      status = ResourceStatus.corrupt;
    }
    _watchdog?.cancel();
    link.resourceConcluded(this);
    if (status == ResourceStatus.corrupt) {
      link.splitBuffers.remove(toHex(originalHash));
      await cancelCorrupt();
    } else if (segmentIndex == totalSegments) {
      callback?.call(this);
    }
  }

  // ============================================================== watchdog

  double _since(DateTime t) =>
      DateTime.now().difference(t).inMicroseconds / 1e6;

  void _startWatchdog() {
    _watchdog?.cancel();
    final id = ++_watchdogId;
    void schedule(double s) {
      _watchdog = Timer(
        Duration(microseconds: (max(s, 0.001) * 1e6).round()),
        () => _watch(id, schedule),
      );
    }

    schedule(0.05);
  }

  Future<void> _watch(int id, void Function(double) schedule) async {
    if (id != _watchdogId) return;
    if (status.index >= ResourceStatus.assembling.index) return;
    double sleep = 0.25;
    switch (status) {
      case ResourceStatus.advertised:
        sleep = _timeout + processingGrace - _since(_advSent);
        if (sleep < 0) {
          if (_retriesLeft <= 0) {
            await cancel();
            return;
          }
          _retriesLeft -= 1;
          if (link.status != LinkStatus.active) {
            await cancel();
            return;
          }
          await link.sendPacket(Packet.resourceAdv, _advPlain!);
          _lastActivity = DateTime.now();
          _advSent = _lastActivity;
          sleep = 0.001;
        }
      case ResourceStatus.transferring:
        if (!initiator) {
          final used = maxRetries - _retriesLeft;
          final extra = used * perRetryDelay;
          _updateEifr();
          final eifr = _eifr!;
          final expectedHmuWait = (_waitingForHmu || _outstanding == 0)
              ? (sdu * 8 * hmuWaitFactor) / eifr
              : 0;
          final expectedTof = (_outstanding * sdu * 8) / eifr;
          final ptf =
              _rtt == null ? partTimeoutFactor : partTimeoutFactorAfterRtt;
          if (_reqRespRttRate != 0) {
            sleep = ptf * expectedTof +
                expectedHmuWait +
                retryGraceTime +
                extra -
                _since(_lastActivity);
          } else {
            sleep = ptf * ((3 * sdu) / eifr) +
                retryGraceTime +
                extra -
                _since(_lastActivity);
          }
          if (sleep < 0) {
            if (_retriesLeft > 0) {
              if (_window > _windowMin) {
                _window -= 1;
                if (_windowMax > _windowMin) {
                  _windowMax -= 1;
                  if (_windowMax - _window > _windowFlex - 1) _windowMax -= 1;
                }
              }
              sleep = 0.001;
              _retriesLeft -= 1;
              _waitingForHmu = false;
              await _requestNext();
            } else {
              await cancel();
              return;
            }
          }
        } else {
          var maxExtra = 0.0;
          for (var r = 0; r < maxRetries; r++) {
            maxExtra += (r + 1) * perRetryDelay;
          }
          final maxWait = (_rtt ?? 1.0) * _timeoutFactor * maxRetries +
              senderGraceTime +
              maxExtra;
          sleep = maxWait - _since(_lastActivity);
          if (sleep < 0) {
            await cancel();
            return;
          }
        }
      case ResourceStatus.awaitingProof:
        _timeoutFactor = proofTimeoutFactor;
        sleep = (_rtt ?? 1.0) * _timeoutFactor +
            senderGraceTime -
            _since(_lastPartSent);
        if (sleep < 0) {
          if (_retriesLeft <= 0) {
            await cancel();
            return;
          }
          _retriesLeft -= 1;
          _lastPartSent = DateTime.now();
          sleep = 0.001;
        }
      default:
        sleep = 0.25;
    }
    schedule(min(sleep, 1.0));
  }

  // ================================================================ cancel

  /// Cancels the transfer (Resource.cancel, Resource.py:1099).
  Future<void> cancel() async {
    if (status == ResourceStatus.corrupt) {
      await cancelCorrupt();
      return;
    }
    if (status.index < ResourceStatus.complete.index) {
      status = ResourceStatus.failed;
      _watchdog?.cancel();
      if (initiator) {
        if (link.status == LinkStatus.active) {
          try {
            await link.sendPacket(Packet.resourceIcl, hash);
          } on Object {
            // best effort
          }
        }
        link.outgoingResources.remove(this);
      } else {
        if (link.status == LinkStatus.active) {
          try {
            await link.sendPacket(Packet.resourceRcl, hash);
          } on Object {
            // best effort
          }
        }
        link.incomingResources.remove(this);
      }
      link.resourceConcluded(this);
      try {
        callback?.call(this);
      } on Object {
        // ignore
      }
    }
  }

  /// Corrupt receive: reject and tear the link down (Resource.py:1103).
  Future<void> cancelCorrupt() async {
    _watchdog?.cancel();
    link.incomingResources.remove(this);
    try {
      callback?.call(this);
    } on Object {
      // ignore
    }
    await link.sendPacket(Packet.resourceRcl, hash);
    await link.teardown();
  }
}
