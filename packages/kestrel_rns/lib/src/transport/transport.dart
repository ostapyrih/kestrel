import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../announce.dart';
import '../crypto/hashes.dart';
import '../crypto/random.dart';
import '../destination.dart';
import '../identity.dart';
import '../interfaces/interface.dart';
import '../link/link.dart';
import '../packet.dart';
import '../stamps.dart';
import '../storage.dart';
import '../util.dart';
import 'receipt.dart';

/// Tunables of the endpoint transport (defaults mirror RNS 1.6.1).
class TransportConfig {
  const TransportConfig({
    this.pathTimeout = const Duration(days: 7),
    this.perHopTimeout = const Duration(seconds: 6),
    this.linkMtuDiscovery = true,
    this.stampAnnounces = true,
    this.announceStampValue = Stamps.defaultDestinationValue,
    this.requiredAnnounceStampCost = Stamps.defaultDestinationCost,
    this.enforceAnnounceStamps = false,
    this.stampPathRequests = true,
    this.pathRequestStampValue = Stamps.defaultPathRequestValue,
    this.implicitProofs = true,
    this.maxResourceSize = 16 * 1024 * 1024,
  });

  /// Transport.PATH_TIMEOUT (Transport.py:227).
  final Duration pathTimeout;

  /// Reticulum.DEFAULT_PER_HOP_TIMEOUT.
  final Duration perHopTimeout;

  /// Reticulum.LINK_MTU_DISCOVERY.
  final bool linkMtuDiscovery;

  /// Transport.STAMP_DESTINATIONS: attach a PoW stamp to own announces.
  final bool stampAnnounces;

  /// Target value of own announce stamps (Transport.DESTINATION_VALUE).
  final double announceStampValue;

  /// Minimum stamp value for a received stamp to count as valid
  /// (Transport.DESTINATION_COST).
  final double requiredAnnounceStampCost;

  /// Drop announces without a valid stamp (Transport.STAMPS_ENFORCED).
  final bool enforceAnnounceStamps;

  /// Transport.STAMP_PRS: attach a PoW stamp to outgoing path requests.
  final bool stampPathRequests;
  final double pathRequestStampValue;

  /// Reticulum.should_use_implicit_proof().
  final bool implicitProofs;

  /// Largest resource (decompressed size) accepted; larger ones are rejected.
  final int maxResourceSize;
}

/// A path to a destination learned from an announce (Transport.path_table).
class PathEntry {
  PathEntry({
    required this.timestamp,
    required this.nextHop,
    required this.hops,
    required this.expires,
    required this.randomBlobs,
    required this.interface,
    required this.announcePacketHash,
  });

  DateTime timestamp;
  Uint8List nextHop;
  int hops;
  DateTime expires;
  final List<String> randomBlobs;
  RnsInterface interface;
  Uint8List announcePacketHash;
  DateTime? used;
  bool unresponsive = false;
}

/// Emitted for every accepted announce.
class AnnounceEvent {
  AnnounceEvent({
    required this.destinationHash,
    required this.identity,
    required this.appData,
    required this.hops,
    required this.isPathResponse,
    required this.announce,
    required this.interface,
  });
  final Uint8List destinationHash;
  final Identity identity;

  /// app_data without a valid stamp trailer.
  final Uint8List appData;
  final int hops;
  final bool isPathResponse;
  final Announce announce;
  final RnsInterface? interface;
}

/// Endpoint-mode Reticulum transport (RNS/Transport.py subset): packet
/// dispatch with duplicate filtering, announce handling and path table,
/// path requests, proofs and receipts, link registry. It never forwards
/// other nodes' traffic.
class Transport {
  Transport({
    required this.storage,
    this.config = const TransportConfig(),
    RandomBytes? random,
  }) : _random = random ?? secureRandomBytes {
    instanceHash = truncatedHash(_random(16));
    pathRequestDestination = Destination.plain(
      'rnstransport',
      ['path', 'request'],
    )..onPacket = _onPathRequest;
    registerDestination(pathRequestDestination);
  }

  final KestrelStorage storage;
  final TransportConfig config;
  final RandomBytes _random;

  /// Wall clock in unix seconds used for announce emission times (tests and
  /// clock-skew simulations replace it).
  int Function() clockSeconds =
      () => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// This instance's transport id, sent in path requests (Transport.identity).
  late final Uint8List instanceHash;
  late final Destination pathRequestDestination;

  final List<RnsInterface> interfaces = [];
  final Map<RnsInterface, StreamSubscription<Uint8List>> _subs = {};
  final Map<String, Destination> _destinations = {};
  final Map<String, PathEntry> _paths = {};
  final Map<String, KnownDestination> _known = {};
  final Map<String, Link> pendingLinks = {};
  final Map<String, Link> activeLinks = {};
  final List<PacketReceipt> _receipts = [];

  Set<String> _hashes = {};
  Set<String> _hashesPrev = {};
  static const int _hashGen = 20000;
  final Set<String> _prTags = {};
  final Map<String, List<Completer<bool>>> _pathWaiters = {};
  final Map<String, Future<Uint8List?>> _stampJobs = {};

  final _announces = StreamController<AnnounceEvent>.broadcast();
  Stream<AnnounceEvent> get announces => _announces.stream;

  Timer? _job;
  Timer? _persistTimer;
  Future<void> _tail = Future.value();
  bool _started = false;

  // ---------------------------------------------------------------- lifecycle

  Future<void> start() async {
    if (_started) return;
    _started = true;
    final kd = await storage.read('known_destinations');
    if (kd != null) {
      for (final e in (kd['entries'] as List<Object?>? ?? const [])) {
        try {
          final k = KnownDestination.fromJson(e! as Map<String, Object?>);
          _known[_hex(k.destinationHash)] = k;
        } on Object {
          // skip corrupt entry
        }
      }
    }
    _job = Timer.periodic(const Duration(seconds: 1), (_) => _jobs());
  }

  Future<void> stop() async {
    _job?.cancel();
    _persistTimer?.cancel();
    for (final l in [...pendingLinks.values, ...activeLinks.values]) {
      await l.teardown();
    }
    await _persistKnown();
    for (final i in [...interfaces]) {
      await removeInterface(i);
    }
    await _announces.close();
    _started = false;
  }

  Future<void> addInterface(RnsInterface i) async {
    interfaces.add(i);
    _subs[i] = i.received.listen((raw) => _enqueue(i, raw));
    await i.start();
  }

  Future<void> removeInterface(RnsInterface i) async {
    await _subs.remove(i)?.cancel();
    interfaces.remove(i);
    await i.stop();
  }

  void _enqueue(RnsInterface iface, Uint8List raw) {
    _tail = _tail.then((_) => _inbound(raw, iface)).catchError((Object _) {});
  }

  /// Feeds a raw packet as if received on [iface] (used by tests).
  Future<void> injectInbound(Uint8List raw, RnsInterface iface) {
    _enqueue(iface, raw);
    return _tail;
  }

  // ------------------------------------------------------------ registries

  void registerDestination(Destination d) {
    if (d.direction != DestinationDirection.inbound) return;
    _destinations[_hex(d.hash)] = d;
  }

  void deregisterDestination(Destination d) =>
      _destinations.remove(_hex(d.hash));

  Destination? localDestination(List<int> hash) => _destinations[_hex(hash)];

  void registerPendingLink(Link l) => pendingLinks[_hex(l.linkId)] = l;

  void activateLink(Link l) {
    pendingLinks.remove(_hex(l.linkId));
    activeLinks[_hex(l.linkId)] = l;
  }

  void registerLink(Link l) => activeLinks[_hex(l.linkId)] = l;

  void unregisterLink(Link l) {
    pendingLinks.remove(_hex(l.linkId));
    activeLinks.remove(_hex(l.linkId));
  }

  // --------------------------------------------------------------- queries

  /// Identity for a destination hash learned from an announce
  /// (Identity.recall).
  Identity? recallIdentity(List<int> destinationHash) {
    final k = _known[_hex(destinationHash)];
    return k == null ? null : Identity.fromPublicKey(k.publicKey);
  }

  /// Remembers the destination `appName.aspects` of an identity whose public
  /// key was learned out of band (Identity.remember without an announce), so
  /// that [recallIdentity] / [outboundDestination] work for it. Never
  /// replaces an existing entry. Returns the destination hash.
  Uint8List rememberDestination(
    List<int> publicKey,
    String appName,
    List<String> aspects,
  ) {
    final id = Identity.fromPublicKey(publicKey);
    final hash = Destination.hashFor(id, appName, aspects);
    _known.putIfAbsent(
      _hex(hash),
      () => KnownDestination(
        destinationHash: hash,
        publicKey: id.publicKey,
        timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
        packetHash: Uint8List(32),
      ),
    );
    return hash;
  }

  KnownDestination? recall(List<int> destinationHash) =>
      _known[_hex(destinationHash)];

  /// Latest ratchet public key announced by [destinationHash] (null if none).
  Uint8List? recallRatchet(List<int> destinationHash) =>
      _known[_hex(destinationHash)]?.ratchet;

  /// Recalls the app_data of the last announce.
  Uint8List? recallAppData(List<int> destinationHash) =>
      _known[_hex(destinationHash)]?.appData;

  Iterable<KnownDestination> get knownDestinations => _known.values;

  /// Builds an outbound SINGLE destination from a recalled identity.
  Destination? outboundDestination(
    List<int> destinationHash,
    String appName,
    List<String> aspects,
  ) {
    final id = recallIdentity(destinationHash);
    if (id == null) return null;
    final d = Destination.single(id, appName, aspects,
        direction: DestinationDirection.outbound);
    if (_hex(d.hash) != _hex(destinationHash)) return null;
    return d;
  }

  PathEntry? pathTo(List<int> destinationHash) {
    final e = _paths[_hex(destinationHash)];
    if (e == null) return null;
    if (DateTime.now().isAfter(e.expires)) {
      _paths.remove(_hex(destinationHash));
      return null;
    }
    return e;
  }

  bool hasPath(List<int> destinationHash) => pathTo(destinationHash) != null;

  /// Hops to the destination, or [Packet.pathfinderM] if unknown.
  int hopsTo(List<int> destinationHash) =>
      pathTo(destinationHash)?.hops ?? Packet.pathfinderM;

  Uint8List? nextHop(List<int> destinationHash) =>
      pathTo(destinationHash)?.nextHop;

  RnsInterface? nextHopInterface(List<int> destinationHash) =>
      pathTo(destinationHash)?.interface;

  void expirePath(List<int> destinationHash) =>
      _paths.remove(_hex(destinationHash));

  /// Transport.first_hop_timeout (Transport.py:3745), seconds.
  double firstHopTimeout(List<int> destinationHash) {
    final i = nextHopInterface(destinationHash);
    final base = config.perHopTimeout.inMilliseconds / 1000;
    if (i == null || i.bitrate <= 0) return base;
    return Packet.mtu * 8 / i.bitrate + base;
  }

  // ---------------------------------------------------------------- outbound

  /// Result of [outbound].
  /// [sent] is false if no interface could carry the packet.

  /// Transmits [p] (Transport.outbound, Transport.py:1655). Link packets go
  /// out on the link's interface; others follow the path table (HEADER_2 via
  /// the next hop when more than one hop away) or are broadcast.
  Future<({bool sent, PacketReceipt? receipt})> outbound(
    Packet p, {
    RnsInterface? attached,
    Destination? destination,
    Link? link,
    bool createReceipt = false,
  }) async {
    if (p.hops >= Packet.pathfinderM - 0) return (sent: false, receipt: null);
    final raw = p.pack();
    var sent = false;

    final isLink = link != null;
    final entry = (p.packetType != Packet.typeAnnounce &&
            !isLink &&
            p.destinationType != DestinationType.plain &&
            p.destinationType != DestinationType.group)
        ? pathTo(p.destinationHash)
        : null;

    if (entry != null) {
      entry.used = DateTime.now();
      if (entry.hops > 1 && p.headerType == Packet.header1) {
        final newFlags =
            (Packet.header2 << 6) | (Packet.transport << 4) | (p.flags & 0x0F);
        final out = BytesBuilder(copy: false)
          ..addByte(newFlags)
          ..addByte(raw[1])
          ..add(entry.nextHop)
          ..add(raw.sublist(2));
        sent = await entry.interface.send(out.toBytes());
      } else {
        sent = await entry.interface.send(raw);
      }
    } else {
      final List<RnsInterface> targets;
      if (isLink) {
        final ai = link.attachedInterface;
        targets = ai == null ? const [] : [ai];
      } else if (attached != null) {
        targets = [attached];
      } else {
        targets = interfaces;
      }
      for (final i in targets) {
        if (!i.online) continue;
        if (await i.send(raw)) sent = true;
      }
    }

    PacketReceipt? receipt;
    final c = p.context;
    if (sent &&
        createReceipt &&
        p.packetType == Packet.typeData &&
        p.destinationType != DestinationType.plain &&
        !(c >= Packet.keepalive && c <= Packet.lrProof) &&
        !(c >= Packet.resource && c <= Packet.resourceRcl)) {
      double timeout;
      if (link != null) {
        timeout = ((link.rtt ?? 1.0) * link.trafficTimeoutFactor);
        final dest = link.destination?.hash;
        if (dest != null) {
          final i = link.attachedInterface ?? nextHopInterface(dest);
          final slowAir = i != null && i.bitrate > 0 && i.bitrate < 50000
              ? Packet.mtu * 8 / i.bitrate
              : 0.0;
          final minHopTimeout = firstHopTimeout(dest) +
              slowAir +
              config.perHopTimeout.inMilliseconds /
                  1000 *
                  hopsTo(dest).clamp(0, 128);
          if (timeout < minHopTimeout) timeout = minHopTimeout;
        }
        if (timeout < 0.005) timeout = 0.005;
      } else {
        timeout = firstHopTimeout(p.destinationHash) +
            config.perHopTimeout.inMilliseconds /
                1000 *
                hopsTo(p.destinationHash).clamp(0, 128);
      }
      receipt = PacketReceipt(
        hash: p.packetHash,
        destination: destination,
        timeout: timeout,
        linkValidator: link?.validate,
      );
      _receipts.add(receipt);
    }
    return (sent: sent, receipt: receipt);
  }

  /// Encrypts [data] for SINGLE [destination] (with its announced ratchet if
  /// known) and sends it as a DATA packet. Returns the receipt.
  Future<PacketReceipt?> sendData(
    Destination destination,
    List<int> data, {
    bool createReceipt = true,
    RnsInterface? attached,
  }) async {
    final Uint8List body;
    if (destination.type == DestinationType.plain) {
      body = Uint8List.fromList(data);
    } else {
      body = await destination.encrypt(
        data,
        ratchet: _known[_hex(destination.hash)]?.ratchet,
      );
    }
    final p = Packet(
      destinationHash: destination.hash,
      data: body,
      destinationType: destination.type,
    );
    final r = await outbound(
      p,
      attached: attached,
      destination: destination,
      createReceipt: createReceipt,
    );
    return r.receipt;
  }

  // ----------------------------------------------------------------- announce

  /// Emits an announce for the inbound SINGLE [destination]
  /// (Destination.announce/_announce, Destination.py:290-350). Generates (and
  /// persists) the PoW stamp first when enabled; that runs on a background
  /// isolate. Returns false if the announce could not be sent.
  Future<bool> announce(
    Destination destination, {
    List<int>? appData,
    bool pathResponse = false,
    RnsInterface? attached,
  }) async {
    if (destination.type != DestinationType.single) {
      throw ArgumentError('Only SINGLE destination types can be announced');
    }
    if (destination.direction != DestinationDirection.inbound) {
      throw ArgumentError('Only IN destination types can be announced');
    }
    // A silent destination (device group, not the announcer) is never
    // announced, path responses included.
    if (destination.silent) return false;
    Uint8List? ratchet;
    final rs = destination.ratchets;
    if (rs != null) {
      if (rs.isEmpty && !destination.ratchetRotationAllowed) {
        ratchet = null;
      } else {
        ratchet = await destination.rotateRatchets(nowSeconds: clockSeconds());
      }
    }
    final app = appData ?? destination.defaultAppData;
    Uint8List? stamp;
    if (config.stampAnnounces) {
      stamp = await ensureStamp(destination);
      if (stamp == null) return false;
    }
    final p = await Announce.build(
      destination,
      appData: app,
      ratchetPublic: ratchet,
      timestamp:
          destination.announceTimebase?.next(nowSeconds: clockSeconds()) ??
              clockSeconds(),
      pathResponse: pathResponse,
      stamp: stamp,
      linkCost: destination.linkCost,
      random: _random,
    );
    final r = await outbound(p, attached: attached);
    return r.sent;
  }

  /// Returns the destination's announce stamp, loading a persisted one or
  /// generating it off the main isolate (Destination._await_stamp).
  Future<Uint8List?> ensureStamp(Destination d) {
    final key = _hex(d.hash);
    return _stampJobs.putIfAbsent(key, () async {
      try {
        final target = config.announceStampValue;
        final wb = Stamps.destinationMaterial(
          d.hash,
          d.identity!.publicKey,
          d.nameHash,
        );
        final cached = d.stamp;
        if (cached != null && Stamps.isValid(cached, target, wb)) return cached;
        final stored = await storage.read('stamp/$key');
        if (stored != null) {
          final s = _b64(stored['stamp']);
          if (s != null &&
              s.length == Stamps.stampLength &&
              Stamps.isValid(s, target, wb)) {
            d.stamp = s;
            d.stampValue = Stamps.value(wb, s);
            return s;
          }
        }
        final s = await Stamps.generateAsync(wb, target);
        if (s == null) return null;
        d.stamp = s;
        d.stampValue = Stamps.value(wb, s);
        await storage.write('stamp/$key', {
          'v': 1,
          'stamp': _b64e(s),
          'value': d.stampValue,
        });
        return s;
      } finally {
        unawaited(
            Future<void>.delayed(Duration.zero, () => _stampJobs.remove(key)));
      }
    });
  }

  /// The destination's announce stamp if one exists (in memory or persisted)
  /// and is valid for the configured target; never generates one. The stamp
  /// material is `hash + public_key + name_hash`, so the stamp is identical on
  /// every device holding the same identity and can be copied instead of
  /// regenerated (device group, docs/spikes/device-group.md section 8).
  Future<Uint8List?> exportStamp(Destination d) async {
    final wb =
        Stamps.destinationMaterial(d.hash, d.identity!.publicKey, d.nameHash);
    final target = config.announceStampValue;
    final cached = d.stamp;
    if (cached != null && Stamps.isValid(cached, target, wb)) return cached;
    final stored = await storage.read('stamp/${_hex(d.hash)}');
    final s = _b64(stored?['stamp']);
    if (s != null &&
        s.length == Stamps.stampLength &&
        Stamps.isValid(s, target, wb)) {
      return s;
    }
    return null;
  }

  /// Adopts a stamp copied from a sibling device. Returns false (and changes
  /// nothing) if it is not a valid stamp for [d] at the configured target.
  Future<bool> importStamp(Destination d, List<int> stamp) async {
    if (stamp.length != Stamps.stampLength) return false;
    final wb =
        Stamps.destinationMaterial(d.hash, d.identity!.publicKey, d.nameHash);
    final s = Uint8List.fromList(stamp);
    if (!Stamps.isValid(s, config.announceStampValue, wb)) return false;
    d.stamp = s;
    d.stampValue = Stamps.value(wb, s);
    await storage.write('stamp/${_hex(d.hash)}', {
      'v': 1,
      'stamp': _b64e(s),
      'value': d.stampValue,
    });
    return true;
  }

  // ------------------------------------------------------------ path requests

  /// Sends a path request for [destinationHash] on all (or [on]) interfaces
  /// (Transport.request_path, Transport.py:3905). Optionally carries a PoW
  /// stamp (cost [TransportConfig.pathRequestStampValue]).
  Future<void> requestPath(
    List<int> destinationHash, {
    RnsInterface? on,
  }) async {
    final tag = _random(16);
    final data = BytesBuilder(copy: false)
      ..add(destinationHash)
      ..add(instanceHash)
      ..add(tag);
    if (config.stampPathRequests) {
      final wb = Stamps.pathRequestMaterial(destinationHash, tag);
      final stamp =
          await Stamps.generateAsync(wb, config.pathRequestStampValue);
      if (stamp != null) {
        data
          ..addByte(Announce.extPayloadMarker)
          ..addByte(0x00)
          ..add(stamp);
      }
    }
    final p = Packet(
      destinationHash: pathRequestDestination.hash,
      data: data.toBytes(),
      destinationType: DestinationType.plain,
    );
    await outbound(p, attached: on);
  }

  /// Waits until a path to [destinationHash] is known, requesting it if
  /// needed (Transport.await_path). Returns whether a path is available.
  Future<bool> awaitPath(
    List<int> destinationHash, {
    Duration timeout = const Duration(seconds: 15),
    bool request = true,
  }) async {
    if (hasPath(destinationHash)) return true;
    final c = Completer<bool>();
    _pathWaiters.putIfAbsent(_hex(destinationHash), () => []).add(c);
    if (request) await requestPath(destinationHash);
    return c.future.timeout(timeout, onTimeout: () {
      _pathWaiters[_hex(destinationHash)]?.remove(c);
      return hasPath(destinationHash);
    });
  }

  /// Handler for packets to `rnstransport.path.request` (path_request_handler,
  /// Transport.py:3964, parse_path_request :4198). As an endpoint we answer
  /// only for our own destinations.
  void _onPathRequest(Uint8List data, Packet packet) {
    const dl = 16;
    if (data.length < dl) return;
    final dest = data.sublist(0, dl);
    Uint8List tag;
    if (data.length == 3 * dl + 2 + Stamps.stampLength) {
      tag = data.sublist(2 * dl, 3 * dl);
    } else if (data.length > 2 * dl) {
      tag = data.sublist(2 * dl, data.length > 3 * dl ? 3 * dl : data.length);
    } else if (data.length > dl) {
      tag = data.sublist(dl);
    } else {
      return;
    }
    final unique = _hex([...dest, ...tag]);
    if (_prTags.contains(unique)) return;
    _prTags.add(unique);
    if (_prTags.length > 4096) _prTags.clear();
    final local = _destinations[_hex(dest)];
    if (local != null &&
        !local.silent &&
        local.type == DestinationType.single &&
        local.direction == DestinationDirection.inbound) {
      unawaited(announce(
        local,
        pathResponse: true,
        attached: packet.receivingInterface,
      ));
    }
  }

  // ------------------------------------------------------------------ inbound

  void _remember(String h) {
    _hashes.add(h);
    if (_hashes.length > _hashGen) {
      _hashesPrev = _hashes;
      _hashes = {};
    }
  }

  bool _seen(String h) => _hashes.contains(h) || _hashesPrev.contains(h);

  /// Packet filter (Transport.packet_filter, Transport.py:1916).
  bool _filter(Packet p) {
    if (p.transportId != null && p.packetType != Packet.typeAnnounce) {
      // Addressed to another transport instance; endpoints never forward.
      return false;
    }
    final c = p.context;
    if (c == Packet.keepalive ||
        c == Packet.resourceReq ||
        c == Packet.resourcePrf ||
        c == Packet.resource ||
        c == Packet.cacheRequest ||
        c == Packet.channel) {
      return true;
    }
    if (p.destinationType == DestinationType.plain ||
        p.destinationType == DestinationType.group) {
      if (p.packetType == Packet.typeAnnounce) return false;
      return p.hops <= 1;
    }
    if (!_seen(_hex(p.packetHash))) return true;
    return p.packetType == Packet.typeAnnounce &&
        p.destinationType == DestinationType.single;
  }

  Future<void> _inbound(Uint8List raw, RnsInterface iface) async {
    final p = Packet.tryUnpack(raw);
    if (p == null) return;
    if (!_filter(p)) return;
    p.receivingInterface = iface;
    p.hops += 1;

    if (!(p.packetType == Packet.typeProof && p.context == Packet.lrProof)) {
      _remember(_hex(p.packetHash));
    }

    switch (p.packetType) {
      case Packet.typeAnnounce:
        await _handleAnnounce(p);
      case Packet.typeLinkRequest:
        await _handleLinkRequest(p);
      case Packet.typeData:
        await _handleData(p);
      case Packet.typeProof:
        await _handleProof(p);
    }
  }

  Future<void> _handleLinkRequest(Packet p) async {
    final d = _destinations[_hex(p.destinationHash)];
    if (d == null || d.type != p.destinationType) return;
    if (!d.acceptLinkRequests) return;
    final link = await Link.validateRequest(this, d, p);
    if (link != null) d.links.add(link);
  }

  Future<void> _handleData(Packet p) async {
    if (p.destinationType == DestinationType.link) {
      final link = activeLinks[_hex(p.destinationHash)];
      if (link == null) return;
      if (!identical(link.attachedInterface, p.receivingInterface)) {
        _hashes.remove(_hex(p.packetHash));
        return;
      }
      await link.receive(p);
      return;
    }
    final d = _destinations[_hex(p.destinationHash)];
    if (d == null || d.type != p.destinationType) return;
    final Uint8List? plain;
    if (d.type == DestinationType.plain) {
      plain = p.data;
    } else {
      plain = await d.decrypt(
        p.data,
        ratchets: d.ratchets,
        enforceRatchets: d.enforceRatchets,
      );
    }
    if (plain == null) return;
    try {
      d.onPacket?.call(plain, p);
    } on Object {
      // application callback errors never break the transport
    }
    if (d.type == DestinationType.single) {
      if (d.proofStrategy == ProofStrategy.all) {
        await prove(p, d);
      } else if (d.proofStrategy == ProofStrategy.app) {
        final cb = d.onProofRequested;
        if (cb != null && cb(p)) await prove(p, d);
      }
    }
  }

  /// Proves [packet] to its sender with [destination]'s identity key
  /// (Identity.prove, Identity.py:1325): implicit proof = signature over the
  /// full packet hash, addressed to the truncated packet hash.
  Future<void> prove(Packet packet, Destination destination) async {
    final id = destination.identity;
    if (id == null || !id.hasPrivateKey) return;
    final sig = await id.sign(packet.packetHash);
    final data = config.implicitProofs
        ? sig
        : Uint8List.fromList([...packet.packetHash, ...sig]);
    final proof = Packet(
      destinationHash: packet.truncatedPacketHash,
      data: data,
      packetType: Packet.typeProof,
      destinationType: DestinationType.single,
    );
    await outbound(proof, attached: packet.receivingInterface);
  }

  Future<void> _handleProof(Packet p) async {
    if (p.context == Packet.lrProof) {
      final link = pendingLinks[_hex(p.destinationHash)];
      if (link != null) {
        _remember(_hex(p.packetHash));
        await link.validateProof(p);
      }
      return;
    }
    if (p.context == Packet.resourcePrf) {
      await activeLinks[_hex(p.destinationHash)]?.receive(p);
      return;
    }
    final onLink = p.destinationType == DestinationType.link;
    final pf = p.data;
    final candidates = <PacketReceipt>[];
    for (final r in _receipts) {
      if (r.status != ReceiptStatus.sent) continue;
      if (pf.length == 96 && !constantTimeEquals(pf.sublist(0, 32), r.hash)) {
        continue;
      }
      candidates.add(r);
    }
    for (final r in candidates) {
      if (await r.validateProof(pf, onLink: onLink)) {
        _receipts.remove(r);
        break;
      }
    }
  }

  // ----------------------------------------------------------------- announces

  int _timebase(Iterable<String> blobs) {
    var t = 0;
    for (final b in blobs) {
      t = t > _blobTime(b) ? t : _blobTime(b);
    }
    return t;
  }

  int _blobTime(String hexBlob) {
    // bytes 5..10 big endian
    return int.parse(hexBlob.substring(10, 20), radix: 16);
  }

  Future<void> _handleAnnounce(Packet p) async {
    final ann = await Announce.validate(
      p,
      requiredStampCost: config.requiredAnnounceStampCost,
      enforceStamps: config.enforceAnnounceStamps,
    );
    if (ann == null) return;
    final hex = _hex(p.destinationHash);
    if (_destinations.containsKey(hex)) return; // our own announce echoed

    final known = _known[hex];
    if (known != null && !constantTimeEquals(known.publicKey, ann.publicKey)) {
      return; // hash collision / forgery (Identity.py:915)
    }

    // remember (Identity.remember)
    final now = DateTime.now();
    final ts = now.millisecondsSinceEpoch / 1000;
    if (known == null) {
      _known[hex] = KnownDestination(
        destinationHash: p.destinationHash,
        publicKey: ann.publicKey,
        timestamp: ts,
        packetHash: p.packetHash,
        appData: ann.payloadAppData.isEmpty ? null : ann.payloadAppData,
        ratchet: ann.hasRatchet ? ann.ratchet : null,
        stampValue: ann.stampValue,
        linkCost: ann.linkCost,
      );
    } else {
      known
        ..timestamp = ts
        ..packetHash = p.packetHash
        ..appData = ann.payloadAppData.isEmpty ? null : ann.payloadAppData
        ..stampValue = ann.stampValue
        ..linkCost = ann.linkCost;
      if (ann.hasRatchet) known.ratchet = ann.ratchet;
    }
    _schedulePersist();

    // Path table decision (Transport.py:2606-2700).
    final receivedFrom = p.transportId ?? p.destinationHash;
    final blob = _hex(ann.randomHash);
    final emitted = ann.emittedAt;
    final existing = _paths[hex];
    var shouldAdd = false;
    if (existing == null) {
      shouldAdd = true;
    } else {
      final blobs = existing.randomBlobs;
      if (p.hops <= existing.hops) {
        shouldAdd = !blobs.contains(blob) && emitted > _timebase(blobs);
      } else if (now.isAfter(existing.expires)) {
        shouldAdd = !blobs.contains(blob);
      } else {
        final pe = _timebase(blobs);
        if (emitted > pe) {
          shouldAdd = !blobs.contains(blob);
        } else if (emitted == pe && existing.unresponsive) {
          shouldAdd = true;
        }
      }
    }
    if (!shouldAdd) return;

    final blobs = existing?.randomBlobs ?? <String>[];
    if (!blobs.contains(blob)) blobs.add(blob);
    while (blobs.length > 64) {
      blobs.removeAt(0);
    }
    _paths[hex] = PathEntry(
      timestamp: now,
      nextHop: receivedFrom,
      hops: p.hops,
      expires: now.add(config.pathTimeout),
      randomBlobs: blobs,
      interface: p.receivingInterface!,
      announcePacketHash: p.packetHash,
    )..used = existing?.used;

    final waiters = _pathWaiters.remove(hex);
    if (waiters != null) {
      for (final w in waiters) {
        if (!w.isCompleted) w.complete(true);
      }
    }
    if (!_announces.isClosed) {
      _announces.add(AnnounceEvent(
        destinationHash: p.destinationHash,
        identity: ann.identity,
        appData: ann.payloadAppData,
        hops: p.hops,
        isPathResponse: p.context == Packet.pathResponse,
        announce: ann,
        interface: p.receivingInterface,
      ));
    }
  }

  // --------------------------------------------------------------------- jobs

  void _jobs() {
    final expired = <PacketReceipt>[];
    for (final r in _receipts) {
      if (r.status != ReceiptStatus.sent) {
        expired.add(r);
      } else if (r.isTimedOut) {
        r.expire();
        expired.add(r);
      }
    }
    _receipts.removeWhere(expired.contains);
    if (_receipts.length > 1024) {
      _receipts.removeRange(0, _receipts.length - 1024);
    }
    final now = DateTime.now();
    _paths.removeWhere((_, e) => now.isAfter(e.expires));
  }

  void _schedulePersist() {
    _persistTimer ??= Timer(const Duration(seconds: 2), () {
      _persistTimer = null;
      unawaited(_persistKnown());
    });
  }

  Future<void> _persistKnown() async {
    await storage.write('known_destinations', {
      'entries': [for (final k in _known.values) k.toJson()],
    });
  }

  /// Forces known-destination persistence (e.g. before app suspend).
  Future<void> flush() => _persistKnown();
}

String _hex(List<int> b) => toHex(b);

Uint8List? _b64(Object? v) {
  if (v is! String) return null;
  try {
    return base64Decode(v);
  } on Object {
    return null;
  }
}

String _b64e(List<int> b) => base64Encode(b);
