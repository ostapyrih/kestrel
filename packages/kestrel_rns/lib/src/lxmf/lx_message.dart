import 'dart:convert';
import 'dart:typed_data';

import '../crypto/hashes.dart';
import '../destination.dart';
import '../identity.dart';
import '../msgpack/msgpack.dart';
import '../packet.dart';

/// LXMF field ids (LXMF/LXMF.py:8-51). Fields are an int-keyed map.
abstract final class LxmfField {
  static const int embeddedLxms = 0x01;
  static const int telemetry = 0x02;
  static const int telemetryStream = 0x03;
  static const int iconAppearance = 0x04;
  static const int fileAttachments = 0x05;
  static const int image = 0x06;
  static const int audio = 0x07;
  static const int thread = 0x08;
  static const int commands = 0x09;
  static const int results = 0x0A;
  static const int group = 0x0B;
  static const int ticket = 0x0C;
  static const int event = 0x0D;
  static const int rnrRefs = 0x0E;
  static const int renderer = 0x0F;
  static const int replyTo = 0x30;
  static const int replyQuote = 0x31;
  static const int reaction = 0x40;
  static const int comment = 0x41;
  static const int continuation = 0x42;
  static const int customType = 0xFB;
  static const int customData = 0xFC;
  static const int customMeta = 0xFD;
  static const int nonSpecific = 0xFE;
  static const int debug = 0xFF;
}

/// Delivery methods (LXMessage.py:48-52).
abstract final class LxmfMethod {
  static const int unknown = 0x00;
  static const int opportunistic = 0x01;
  static const int direct = 0x02;
  static const int propagated = 0x03;
  static const int paper = 0x05;
}

/// How a packed message is carried (LXMessage.py:42-45).
abstract final class LxmfRepresentation {
  static const int unknown = 0x00;
  static const int packet = 0x01;
  static const int resource = 0x02;
}

/// Why a received message is unverified (LXMessage.py:54-56).
abstract final class LxmfUnverifiedReason {
  static const int sourceUnknown = 0x01;
  static const int signatureInvalid = 0x02;
}

/// Result of [LXMessage.propagationPacked].
class LxmfPropagationPacked {
  const LxmfPropagationPacked({
    required this.packed,
    required this.transientId,
    required this.lxmfData,
    required this.timestamp,
  });

  /// `msgpack([timestamp, [lxmf_data]])`, the payload sent to a propagation
  /// node.
  final Uint8List packed;

  /// SHA-256 of `lxmf_data` (before any propagation stamp is appended).
  final Uint8List transientId;

  /// `destination_hash || encrypt(packed[16:])` (without the stamp).
  final Uint8List lxmfData;

  /// The timestamp inside [packed].
  final double timestamp;

  /// The payload with [stamp] appended to the message (the transient id and
  /// the encrypted data stay unchanged).
  Uint8List withStamp(List<int> stamp) => packb(<Object?>[
        timestamp,
        <Object?>[
          (BytesBuilder(copy: false)
                ..add(lxmfData)
                ..add(stamp))
              .toBytes(),
        ],
      ]);
}

/// An LXMF message (LXMF/LXMessage.py).
///
/// Packed format: `dest_hash(16) || source_hash(16) || signature(64) ||
/// msgpack([timestamp(float64), title(bin), content(bin), fields(map)
/// [, stamp(bin)]])`. The message hash is
/// `SHA256(dest || source || msgpack([ts, title, content, fields]))`
/// (stamp excluded) and the signature covers
/// `dest || source || payload || hash` (LXMessage.pack, :380-410).
class LXMessage {
  LXMessage({
    required this.destinationHash,
    required this.sourceHash,
    Object content = '',
    Object title = '',
    Map<Object?, Object?>? fields,
    this.timestamp,
    this.desiredMethod = LxmfMethod.direct,
  })  : title = _toBytes(title),
        content = _toBytes(content),
        fields = fields ?? <Object?, Object?>{};

  static const int destinationLength = 16;
  static const int signatureLength = 64;
  static const int timestampSize = 8;
  static const int structOverhead = 8;
  static const int lxmfOverhead =
      2 * destinationLength + signatureLength + timestampSize + structOverhead;

  /// RNS.Packet.ENCRYPTED_MDU =
  /// floor((MDU - TOKEN_OVERHEAD - KEYSIZE/16) / 16) * 16 - 1 (Packet.py:129).
  static const int encryptedPacketMdu = ((Packet.mdu - 48 - 32) ~/ 16) * 16 - 1;
  static const int encryptedPacketMaxContent =
      encryptedPacketMdu - lxmfOverhead + destinationLength;

  /// RNS.Link.MDU (floor((MTU-IFAC_MIN-HEADER_MIN-TOKEN_OVERHEAD)/16)*16-1).
  static const int linkPacketMdu =
      ((Packet.mtu - Packet.ifacMinSize - Packet.headerMinSize - 48) ~/ 16) *
              16 -
          1;
  static const int linkPacketMaxContent = linkPacketMdu - lxmfOverhead;

  Uint8List destinationHash;
  Uint8List sourceHash;
  Uint8List title;
  Uint8List content;
  Map<Object?, Object?> fields;

  /// Unix timestamp in seconds, serialised as float64.
  double? timestamp;
  int desiredMethod;

  Uint8List? signature;
  Uint8List? hash;
  Uint8List? stamp;
  Uint8List? packed;

  /// Chosen delivery method / representation after [pack] (LXMessage.pack).
  int method = LxmfMethod.unknown;
  int representation = LxmfRepresentation.unknown;

  bool incoming = false;
  bool signatureValidated = false;
  int? unverifiedReason;

  static Uint8List _toBytes(Object v) {
    if (v is String) return Uint8List.fromList(utf8.encode(v));
    if (v is Uint8List) return v;
    if (v is List<int>) return Uint8List.fromList(v);
    throw ArgumentError('expected String or bytes');
  }

  String get titleAsString => utf8.decode(title);
  String get contentAsString => utf8.decode(content);

  /// Convenience: message id (same as [hash]).
  Uint8List? get messageId => hash;

  /// `msgpack([timestamp, title, content, fields])`.
  Uint8List _packedPayload({Uint8List? withStamp}) {
    final payload = <Object?>[timestamp, title, content, fields];
    if (withStamp != null) payload.add(withStamp);
    return packb(payload);
  }

  /// SHA-256 stamp for a ticket (LXMessage.get_stamp:253):
  /// `truncated_hash(ticket || message_id)`.
  static Uint8List ticketStamp(List<int> ticket, List<int> messageId) =>
      truncatedHash([...ticket, ...messageId]);

  /// Signs and serialises the message with [sourceIdentity], the identity of
  /// the source `lxmf.delivery` destination. [stamp], if given, is appended as
  /// payload element 5 after hashing/signing. Returns the packed bytes.
  Future<Uint8List> pack(
    Identity sourceIdentity, {
    Uint8List? stamp,
  }) async {
    timestamp ??= DateTime.now().microsecondsSinceEpoch / 1e6;
    final hashedPart = (BytesBuilder(copy: false)
          ..add(destinationHash)
          ..add(sourceHash)
          ..add(_packedPayload()))
        .toBytes();
    final h = sha256(hashedPart);
    hash = h;
    this.stamp = stamp;
    final sig = await sourceIdentity.sign([...hashedPart, ...h]);
    signature = sig;
    signatureValidated = true;

    final packedPayload = _packedPayload(withStamp: stamp);
    final out = (BytesBuilder(copy: false)
          ..add(destinationHash)
          ..add(sourceHash)
          ..add(sig)
          ..add(packedPayload))
        .toBytes();
    packed = out;

    final contentSize = packedPayload.length - timestampSize - structOverhead;
    var wanted = desiredMethod;
    if (wanted == LxmfMethod.opportunistic &&
        contentSize > encryptedPacketMaxContent) {
      wanted = LxmfMethod.direct; // LXMessage.py:413-418
    }
    method = wanted;
    if (wanted == LxmfMethod.opportunistic) {
      representation = LxmfRepresentation.packet;
    } else if (wanted == LxmfMethod.direct) {
      representation = contentSize <= linkPacketMaxContent
          ? LxmfRepresentation.packet
          : LxmfRepresentation.resource;
    }
    return out;
  }

  /// Payload for opportunistic delivery: the packed message without its
  /// leading 16 byte destination hash (LXMessage.__as_packet:664).
  Uint8List get opportunisticPayload =>
      Uint8List.sublistView(packed!, destinationLength);

  /// Builds the propagation-node payload (LXMessage.pack PROPAGATED branch,
  /// :432-440): `msgpack([timestamp_now, [dest_hash || encrypt(packed[16:])]])`.
  Future<LxmfPropagationPacked> propagationPacked(
    Identity recipient, {
    required double now,
    List<int>? ephemeralPrivate,
    List<int>? iv,
    List<int>? ratchet,
    List<int>? propagationStamp,
  }) async {
    final enc = await recipient.encrypt(
      opportunisticPayload,
      ratchet: ratchet,
      ephemeralPrivate: ephemeralPrivate,
      iv: iv,
    );
    final lxmfData = (BytesBuilder(copy: false)
          ..add(destinationHash)
          ..add(enc))
        .toBytes();
    // The transient id never covers the propagation stamp (LXMessage.pack).
    final transientId = sha256(lxmfData);
    final stamped = propagationStamp == null
        ? lxmfData
        : (BytesBuilder(copy: false)
              ..add(lxmfData)
              ..add(propagationStamp))
            .toBytes();
    return LxmfPropagationPacked(
      packed: packb(<Object?>[
        now,
        <Object?>[stamped],
      ]),
      transientId: transientId,
      lxmfData: lxmfData,
      timestamp: now,
    );
  }

  /// Rebuilds the packed form from an opportunistic packet payload
  /// (LXMRouter.delivery_packet, LXMRouter.py:2270): the destination hash
  /// comes from the packet, not the payload.
  static Uint8List fromOpportunisticPayload(
    List<int> destinationHash,
    List<int> payload,
  ) =>
      Uint8List.fromList([...destinationHash, ...payload]);

  /// Parses packed LXMF bytes (LXMessage.unpack_from_bytes, :777).
  ///
  /// If [sourceIdentity] is given the signature is checked; otherwise the
  /// message is marked unverified with `sourceUnknown`.
  static Future<LXMessage> unpackFromBytes(
    List<int> lxmfBytes, {
    Identity? sourceIdentity,
  }) async {
    final bytes = Uint8List.fromList(lxmfBytes);
    const dl = destinationLength;
    if (bytes.length < 2 * dl + signatureLength + 1) {
      throw FormatException('LXMF message too short (${bytes.length} bytes)');
    }
    final destHash = Uint8List.sublistView(bytes, 0, dl);
    final srcHash = Uint8List.sublistView(bytes, dl, 2 * dl);
    final signature =
        Uint8List.sublistView(bytes, 2 * dl, 2 * dl + signatureLength);
    var packedPayload = Uint8List.sublistView(bytes, 2 * dl + signatureLength);
    final unpacked = unpackb(packedPayload);
    if (unpacked is! List<Object?> || unpacked.length < 4) {
      throw const FormatException('LXMF payload is not a 4+ element array');
    }
    Uint8List? stamp;
    List<Object?> payload = unpacked;
    if (unpacked.length > 4) {
      // Python: stamp = payload[4]; payload = payload[:4]; re-pack for hashing
      final s = unpacked[4];
      stamp = s is Uint8List ? s : null;
      payload = unpacked.sublist(0, 4);
      packedPayload = packb(payload);
    }
    final hashedPart = (BytesBuilder(copy: false)
          ..add(destHash)
          ..add(srcHash)
          ..add(packedPayload))
        .toBytes();
    final messageHash = sha256(hashedPart);
    final ts = payload[0];
    final title = payload[1];
    final content = payload[2];
    final fields = payload[3];
    if (ts is! num || title is! Uint8List || content is! Uint8List) {
      throw const FormatException('Malformed LXMF payload types');
    }
    final msg = LXMessage(
      destinationHash: Uint8List.fromList(destHash),
      sourceHash: Uint8List.fromList(srcHash),
      title: title,
      content: content,
      fields: fields is Map<Object?, Object?> ? fields : <Object?, Object?>{},
      timestamp: ts.toDouble(),
    )
      ..hash = messageHash
      ..signature = Uint8List.fromList(signature)
      ..stamp = stamp
      ..packed = bytes
      ..incoming = true;

    if (sourceIdentity != null) {
      final ok = await sourceIdentity
          .validate(signature, [...hashedPart, ...messageHash]);
      msg.signatureValidated = ok;
      if (!ok) msg.unverifiedReason = LxmfUnverifiedReason.signatureInvalid;
    } else {
      msg.unverifiedReason = LxmfUnverifiedReason.sourceUnknown;
    }
    return msg;
  }

  /// `lxmf.delivery` destination hash for [identity].
  static Uint8List deliveryHash(Identity identity) =>
      Destination.hashFor(identity, 'lxmf', const ['delivery']);
}
