import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'crypto/hashes.dart';
import 'crypto/random.dart';
import 'identity.dart';
import 'packet.dart';

/// Destination types (RNS/Destination.py:65-68). Values are the 2-bit wire
/// field in the packet flags.
abstract final class DestinationType {
  static const int single = 0x00;
  static const int group = 0x01;
  static const int plain = 0x02;
  static const int link = 0x03;
}

/// Destination direction (Destination.py:IN/OUT).
enum DestinationDirection { inbound, outbound }

/// Proof strategy for received packets (Destination.PROVE_*).
enum ProofStrategy { none, app, all }

/// Request handler access policy (Destination.ALLOW_*).
enum RequestPolicy { none, all, list }

/// Called with decrypted data and the packet for inbound packets.
typedef PacketCallback = void Function(Uint8List data, Packet packet);

/// Response generator for requests (Destination.register_request_handler).
/// Returns the response object (msgpack-able) or null for no response.
/// [linkId] and [remoteIdentity] (null unless the peer identified) are
/// provided; [requestedAt] is the sender's timestamp.
typedef RequestGenerator = FutureOr<Object?> Function(
  String path,
  Object? data,
  Uint8List requestId,
  Uint8List linkId,
  Identity? remoteIdentity,
  double requestedAt,
);

class RequestHandlerEntry {
  RequestHandlerEntry(
    this.path,
    this.generator,
    this.policy,
    this.allowedList,
    this.autoCompress,
  );
  final String path;
  final RequestGenerator generator;
  final RequestPolicy policy;
  final List<Uint8List> allowedList;
  final bool autoCompress;
}

/// An RNS destination: name + aspects, optionally bound to an [Identity].
///
/// Hash derivation (Destination.py:118-133):
/// `name_hash = SHA256("app.aspect1.aspect2")[:10]`,
/// `hash = SHA256(name_hash || identity_hash)[:16]` (identity part omitted
/// for PLAIN destinations).
class Destination {
  Destination._({
    required this.type,
    required this.appName,
    required this.aspects,
    this.identity,
    DestinationDirection? direction,
  })  : direction = direction ??
            (identity != null && !identity.hasPrivateKey
                ? DestinationDirection.outbound
                : DestinationDirection.inbound),
        name = expandName(identity, appName, aspects),
        nameHash = nameHashFor(appName, aspects),
        hash = hashFor(identity, appName, aspects);

  /// SINGLE destination for [identity] (e.g. `lxmf.delivery`).
  factory Destination.single(
    Identity identity,
    String appName,
    List<String> aspects, {
    DestinationDirection? direction,
  }) =>
      Destination._(
        type: DestinationType.single,
        appName: appName,
        aspects: aspects,
        identity: identity,
        direction: direction,
      );

  /// PLAIN destination (no identity, no encryption).
  factory Destination.plain(
    String appName,
    List<String> aspects, {
    DestinationDirection direction = DestinationDirection.inbound,
  }) =>
      Destination._(
        type: DestinationType.plain,
        appName: appName,
        aspects: aspects,
        direction: direction,
      );

  // ---- runtime state (Destination.py instance attributes) ----

  final DestinationDirection direction;
  ProofStrategy proofStrategy = ProofStrategy.none;
  bool acceptLinkRequests = true;
  int? maxRequestSize;

  /// Called for each decrypted data packet addressed to this destination.
  PacketCallback? onPacket;

  /// For [ProofStrategy.app]: decide whether to prove a packet.
  bool Function(Packet packet)? onProofRequested;

  /// Called with an established inbound [Object] link (a `Link`).
  void Function(Object link)? onLinkEstablished;

  /// Default app_data for announces.
  Uint8List? defaultAppData;

  /// Active inbound links (typed `Link`, kept as Object to avoid a cycle).
  final List<Object> links = [];

  final Map<String, RequestHandlerEntry> requestHandlers = {};

  /// Registers a request handler (Destination.py:480). The path hash is
  /// `truncated_hash(path)`.
  void registerRequestHandler(
    String path,
    RequestGenerator generator, {
    RequestPolicy policy = RequestPolicy.none,
    List<Uint8List> allowedList = const [],
    bool autoCompress = true,
  }) {
    if (path.isEmpty) throw ArgumentError('Invalid path specified');
    requestHandlers[_hex(truncatedHash(utf8.encode(path)))] =
        RequestHandlerEntry(path, generator, policy, allowedList, autoCompress);
  }

  bool deregisterRequestHandler(String path) =>
      requestHandlers.remove(_hex(truncatedHash(utf8.encode(path)))) != null;

  /// Retained private ratchet keys, newest first (null = ratchets disabled).
  List<Uint8List>? ratchets;
  bool enforceRatchets = false;
  int retainedRatchets = 512; // Destination.RATCHET_COUNT
  int ratchetIntervalSeconds = 30 * 60; // Destination.RATCHET_INTERVAL
  int _latestRatchetTime = 0;

  /// Called whenever [ratchets] changed so the owner can persist them.
  FutureOr<void> Function(List<Uint8List> ratchets)? onRatchetsChanged;

  /// Enables ratchets, optionally with previously persisted keys.
  void enableRatchets([List<Uint8List>? existing]) {
    ratchets = [...?existing];
  }

  /// Rotates the ratchet if the interval elapsed and returns the newest
  /// ratchet public key (Destination.rotate_ratchets, Destination.py:244).
  Future<Uint8List> rotateRatchets(
      {int? nowSeconds, RandomBytes? random}) async {
    final r = ratchets;
    if (r == null) throw StateError('ratchets are not enabled');
    final now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (r.isEmpty || now > _latestRatchetTime + ratchetIntervalSeconds) {
      r.insert(0, Identity.generateRatchet(random: random));
      _latestRatchetTime = now;
      if (r.length > retainedRatchets) {
        r.removeRange(retainedRatchets, r.length);
      }
      await onRatchetsChanged?.call(r);
    }
    return Identity.ratchetPublicBytes(r.first);
  }

  /// Stamp for announces (Destination._await_stamp) once generated.
  Uint8List? stamp;
  double? stampValue;

  /// Target announce stamp value (Destination.target_value).
  double targetValue = 25.0;

  /// Link request cost announced in the stamp ext payload.
  double linkCost = 12.5;

  final int type;
  final String appName;
  final List<String> aspects;
  final Identity? identity;
  final String name;
  final Uint8List nameHash;
  final Uint8List hash;

  /// Human readable name, with the identity hex hash appended if given
  /// (Destination.expand_name, Destination.py:98).
  static String expandName(
    Identity? identity,
    String appName,
    List<String> aspects,
  ) {
    if (appName.contains('.')) {
      throw ArgumentError("Dots can't be used in app names");
    }
    final buf = StringBuffer(appName);
    for (final aspect in aspects) {
      if (aspect.contains('.')) {
        throw ArgumentError("Dots can't be used in aspects");
      }
      buf
        ..write('.')
        ..write(aspect);
    }
    if (identity != null) {
      buf
        ..write('.')
        ..write(_hex(identity.hash));
    }
    return buf.toString();
  }

  /// 10 byte name hash for `appName.aspects` (no identity).
  static Uint8List nameHashFor(String appName, List<String> aspects) {
    final full = expandName(null, appName, aspects);
    return Uint8List.sublistView(sha256(utf8.encode(full)), 0, 10);
  }

  /// Name hash for a dotted full name (Destination.name_hash).
  static Uint8List nameHashFromFullName(String fullName) =>
      Uint8List.sublistView(sha256(utf8.encode(fullName)), 0, 10);

  /// Destination hash. [identityOrHash] may be an [Identity], a 16 byte
  /// identity hash, or null (PLAIN).
  static Uint8List hashFor(
    Object? identityOrHash,
    String appName,
    List<String> aspects,
  ) {
    final material = BytesBuilder(copy: false)
      ..add(nameHashFor(appName, aspects));
    if (identityOrHash is Identity) {
      material.add(identityOrHash.hash);
    } else if (identityOrHash is List<int> && identityOrHash.length == 16) {
      material.add(identityOrHash);
    } else if (identityOrHash != null) {
      throw ArgumentError('Invalid material supplied for destination hash '
          'calculation');
    }
    return truncatedHash(material.toBytes());
  }

  /// Encrypts [plaintext] to this destination (Destination.encrypt).
  /// PLAIN destinations return the plaintext unchanged.
  Future<Uint8List> encrypt(
    List<int> plaintext, {
    List<int>? ratchet,
    List<int>? ephemeralPrivate,
    List<int>? iv,
  }) {
    if (type == DestinationType.plain) {
      return Future.value(Uint8List.fromList(plaintext));
    }
    final id = identity;
    if (type == DestinationType.single && id != null) {
      return id.encrypt(
        plaintext,
        ratchet: ratchet,
        ephemeralPrivate: ephemeralPrivate,
        iv: iv,
      );
    }
    throw UnsupportedError('Unsupported destination type for encrypt');
  }

  /// Decrypts a token addressed to this (inbound) destination.
  Future<Uint8List?> decrypt(
    List<int> ciphertext, {
    List<List<int>>? ratchets,
    bool enforceRatchets = false,
  }) {
    if (type == DestinationType.plain) {
      return Future.value(Uint8List.fromList(ciphertext));
    }
    final id = identity;
    if (type == DestinationType.single && id != null) {
      return id.decrypt(
        ciphertext,
        ratchets: ratchets,
        enforceRatchets: enforceRatchets,
      );
    }
    throw UnsupportedError('Unsupported destination type for decrypt');
  }

  @override
  String toString() => '<$name:${_hex(hash)}>';
}

String _hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
