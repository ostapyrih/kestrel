import 'dart:typed_data';

import 'crypto/hashes.dart';
import 'crypto/random.dart';
import 'destination.dart';
import 'identity.dart';
import 'packet.dart';

/// Parsed and validated announce (RNS/Identity.py `validate_announce`,
/// Identity.py:757, and Destination._announce, Destination.py:307).
///
/// Announce data layout:
/// `public_key(64) || name_hash(10) || random_hash(10) || [ratchet(32)] ||
///  signature(64) || [app_data]`; the ratchet is present iff the packet
/// context flag is set. Signed material is
/// `dest_hash || public_key || name_hash || random_hash || ratchet || app_data`.
///
/// Stamps: RNS 1.6 optionally appends an 18-byte "ext payload" (proof of
/// work) to app_data. This core does NOT generate or value-check stamps (not
/// enforced by default, `Transport.STAMPS_ENFORCED = False`); [appData] is
/// the raw trailing bytes including any ext payload, see [stampTrailer].
class Announce {
  Announce._({
    required this.destinationHash,
    required this.publicKey,
    required this.nameHash,
    required this.randomHash,
    required this.ratchet,
    required this.signature,
    required this.appData,
    required this.identity,
    required this.packet,
  });

  static const int ratchetLength = 32;
  static const int randomHashLength = 10;

  /// Marker / sizes of the optional stamp ext payload (Identity.py:86-90).
  static const int extPayloadMarker = 0xC1;
  static const int extHeaderLength = 2;
  static const int stampLength = 14;
  static const int extPayloadLength = 18;

  final Uint8List destinationHash;
  final Uint8List publicKey;
  final Uint8List nameHash;
  final Uint8List randomHash;

  /// Announced ratchet public key; empty if none.
  final Uint8List ratchet;
  final Uint8List signature;

  /// Raw app_data (possibly empty), including any stamp ext payload.
  final Uint8List appData;
  final Identity identity;
  final Packet packet;

  bool get hasRatchet => ratchet.isNotEmpty;

  /// Announce emission timestamp (seconds), embedded in the last 5 bytes of
  /// the random hash (Destination.py:337).
  int get emittedAt {
    var t = 0;
    for (final b in randomHash.sublist(5)) {
      t = (t << 8) | b;
    }
    return t;
  }

  /// If [appData] ends with something shaped like a stamp ext payload
  /// (marker 0xC1 at `len-18`), returns `(stamp, lrCostBytes)`; the stamp is
  /// NOT checked (see class docs).
  ({Uint8List stamp, Uint8List costBytes})? get stampTrailer {
    if (appData.length < extPayloadLength) return null;
    final ext = Uint8List.sublistView(
      appData,
      appData.length - extPayloadLength,
    );
    if (ext[0] != extPayloadMarker) return null;
    return (
      stamp: Uint8List.sublistView(
        ext,
        extHeaderLength,
        extHeaderLength + stampLength,
      ),
      costBytes: Uint8List.sublistView(ext, ext.length - 2),
    );
  }

  /// Builds a signed announce packet for [destination] (which must be a
  /// SINGLE destination whose identity holds a private key).
  ///
  /// [randomHash] (10 bytes) is for deterministic tests; by default it is
  /// 5 random bytes followed by the 5-byte big-endian [timestamp] (unix
  /// seconds), as in Destination.py:337.
  static Future<Packet> build(
    Destination destination, {
    List<int>? appData,
    List<int>? ratchetPublic,
    List<int>? randomHash,
    int? timestamp,
    bool pathResponse = false,
    RandomBytes? random,
  }) async {
    final id = destination.identity;
    if (destination.type != DestinationType.single || id == null) {
      throw ArgumentError('Only SINGLE destinations can be announced');
    }
    final Uint8List rh;
    if (randomHash != null) {
      rh = Uint8List.fromList(randomHash);
    } else {
      final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
      rh = Uint8List(10)..setRange(0, 5, (random ?? secureRandomBytes)(5));
      for (var i = 0; i < 5; i++) {
        rh[5 + i] = (ts >> (8 * (4 - i))) & 0xFF;
      }
    }
    if (rh.length != randomHashLength) {
      throw ArgumentError('random hash must be 10 bytes');
    }
    final ratchet = ratchetPublic ?? const <int>[];
    if (ratchet.isNotEmpty && ratchet.length != ratchetLength) {
      throw ArgumentError('ratchet must be 32 bytes');
    }
    final app = appData ?? const <int>[];
    final pub = id.publicKey;
    final signed = (BytesBuilder(copy: false)
          ..add(destination.hash)
          ..add(pub)
          ..add(destination.nameHash)
          ..add(rh)
          ..add(ratchet)
          ..add(app))
        .toBytes();
    final sig = await id.sign(signed);
    final data = (BytesBuilder(copy: false)
          ..add(pub)
          ..add(destination.nameHash)
          ..add(rh)
          ..add(ratchet)
          ..add(sig)
          ..add(app))
        .toBytes();
    return Packet(
      destinationHash: destination.hash,
      data: data,
      packetType: Packet.typeAnnounce,
      context: pathResponse ? Packet.pathResponse : Packet.noneContext,
      contextFlag: ratchet.isNotEmpty ? 1 : 0,
      destinationType: DestinationType.single,
    );
  }

  /// Parses and validates an announce [packet]; returns null if it is
  /// malformed, the signature is invalid, or the destination hash does not
  /// match `name_hash + identity_hash`.
  static Future<Announce?> validate(Packet packet) async {
    if (packet.packetType != Packet.typeAnnounce) return null;
    const keySize = Identity.keySize;
    const nameLen = Identity.nameHashLength;
    const sigLen = Identity.signatureLength;
    final d = packet.data;
    final hasRatchet = packet.contextFlag == 1;
    final minLen = keySize +
        nameLen +
        randomHashLength +
        sigLen +
        (hasRatchet ? ratchetLength : 0);
    if (d.length < minLen) return null;

    var o = 0;
    Uint8List take(int n) {
      final s = Uint8List.sublistView(d, o, o + n);
      o += n;
      return Uint8List.fromList(s);
    }

    final publicKey = take(keySize);
    final nameHash = take(nameLen);
    final randomHash = take(randomHashLength);
    final ratchet = hasRatchet ? take(ratchetLength) : Uint8List(0);
    final signature = take(sigLen);
    final appData = Uint8List.fromList(d.sublist(o));

    final signed = (BytesBuilder(copy: false)
          ..add(packet.destinationHash)
          ..add(publicKey)
          ..add(nameHash)
          ..add(randomHash)
          ..add(ratchet)
          ..add(appData))
        .toBytes();

    final Identity identity;
    try {
      identity = Identity.fromPublicKey(publicKey);
    } on ArgumentError {
      return null;
    }
    if (!await identity.validate(signature, signed)) return null;

    final expected = truncatedHash([...nameHash, ...identity.hash]);
    if (!constantTimeEquals(expected, packet.destinationHash)) return null;

    return Announce._(
      destinationHash: packet.destinationHash,
      publicKey: publicKey,
      nameHash: nameHash,
      randomHash: randomHash,
      ratchet: ratchet,
      signature: signature,
      appData: appData,
      identity: identity,
      packet: packet,
    );
  }
}
