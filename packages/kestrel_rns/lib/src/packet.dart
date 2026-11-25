import 'dart:typed_data';

import 'crypto/hashes.dart';

/// Thrown for packets that cannot be parsed or serialised.
class PacketException implements Exception {
  PacketException(this.message);
  final String message;
  @override
  String toString() => 'PacketException: $message';
}

/// A Reticulum packet (RNS/Packet.py).
///
/// This class is the pure wire format: [data] is whatever goes after the
/// header (already encrypted when the destination requires it). Encryption is
/// done by the caller via `Destination.encrypt` / link keys.
///
/// Wire layout (Packet.py:pack/unpack):
/// ```
/// HEADER_1: flags(1) hops(1) dest(16)               context(1) data
/// HEADER_2: flags(1) hops(1) transport_id(16) dest(16) context(1) data
/// flags: header_type<<6 | context_flag<<5 | transport_type<<4 |
///        destination_type<<2 | packet_type
/// ```
class Packet {
  Packet({
    required this.destinationHash,
    required this.data,
    this.packetType = typeData,
    this.context = noneContext,
    this.headerType = header1,
    this.contextFlag = 0,
    this.transportType = broadcast,
    this.destinationType = 0,
    this.hops = 0,
    this.transportId,
  });

  // Packet types (Packet.py:66-69)
  static const int typeData = 0x00;
  static const int typeAnnounce = 0x01;
  static const int typeLinkRequest = 0x02;
  static const int typeProof = 0x03;

  // Header types
  static const int header1 = 0x00;
  static const int header2 = 0x01;

  // Transport types (Transport.py:145)
  static const int broadcast = 0x00;
  static const int transport = 0x01;

  // Contexts (Packet.py:77-96)
  static const int noneContext = 0x00;
  static const int resource = 0x01;
  static const int resourceAdv = 0x02;
  static const int resourceReq = 0x03;
  static const int resourceHmu = 0x04;
  static const int resourcePrf = 0x05;
  static const int resourceIcl = 0x06;
  static const int resourceRcl = 0x07;
  static const int cacheRequest = 0x08;
  static const int request = 0x09;
  static const int response = 0x0A;
  static const int pathResponse = 0x0B;
  static const int command = 0x0C;
  static const int commandStatus = 0x0D;
  static const int channel = 0x0E;
  static const int keepalive = 0xFA;
  static const int linkIdentify = 0xFB;
  static const int linkClose = 0xFC;
  static const int linkProof = 0xFD;
  static const int lrRtt = 0xFE;
  static const int lrProof = 0xFF;

  // Size limits (Reticulum.py:94-156)
  static const int mtu = 500;
  static const int truncatedHashLength = 16;
  static const int headerMinSize = 2 + 1 + truncatedHashLength; // 19
  static const int headerMaxSize = 2 + 1 + truncatedHashLength * 2; // 35
  static const int ifacMinSize = 1;
  static const int mdu = mtu - headerMaxSize - ifacMinSize; // 464

  /// Maximum hop count; packets with `hops >= 128` are dropped
  /// (Transport.PATHFINDER_M, Packet.py:271).
  static const int pathfinderM = 128;

  int headerType;
  int contextFlag;
  int transportType;
  int destinationType;
  int packetType;
  int hops;
  int context;
  Uint8List? transportId;
  Uint8List destinationHash;
  Uint8List data;

  /// Packed flag byte (Packet.get_packed_flags).
  int get flags =>
      (headerType << 6) |
      (contextFlag << 5) |
      (transportType << 4) |
      (destinationType << 2) |
      packetType;

  /// Serialises the packet. Throws [PacketException] if HEADER_2 lacks a
  /// transport id or the packet exceeds the MTU (Packet.py:225-236).
  Uint8List pack() {
    if (destinationHash.length != truncatedHashLength) {
      throw PacketException('Destination hash must be 16 bytes');
    }
    final b = BytesBuilder(copy: false)
      ..addByte(flags)
      ..addByte(hops);
    if (headerType == header2) {
      final tid = transportId;
      if (tid == null || tid.length != truncatedHashLength) {
        throw PacketException('Packet with header type 2 must have a '
            'transport ID');
      }
      b.add(tid);
    }
    b
      ..add(destinationHash)
      ..addByte(context)
      ..add(data);
    final raw = b.toBytes();
    if (packetType == typeAnnounce &&
        headerType == header1 &&
        raw.length + truncatedHashLength > mtu) {
      throw PacketException(
        'Transport-inserted announce packet size of '
        '${raw.length + truncatedHashLength} exceeds MTU of $mtu bytes',
      );
    }
    if (raw.length > mtu) {
      throw PacketException(
        'Packet size of ${raw.length} exceeds MTU of $mtu bytes',
      );
    }
    return raw;
  }

  /// Parses [raw] (Packet.unpack, Packet.py:262). Throws [PacketException]
  /// for anything the reference would drop as malformed.
  factory Packet.unpack(List<int> raw) {
    if (raw.length < 2) throw PacketException('Packet too short');
    final flags = raw[0];
    final hops = raw[1];
    if (hops >= pathfinderM) {
      throw PacketException('Invalid hop count $hops');
    }
    final headerType = (flags & 0x40) >> 6;
    final contextFlag = (flags & 0x20) >> 5;
    final transportType = (flags & 0x10) >> 4;
    final destinationType = (flags & 0x0C) >> 2;
    final packetType = flags & 0x03;
    const dst = truncatedHashLength;

    Uint8List? transportId;
    late Uint8List destHash;
    late int context;
    late Uint8List body;
    if (headerType == header2) {
      if (raw.length < 2 + 2 * dst + 1) {
        throw PacketException('Malformed HEADER_2 packet');
      }
      transportId = Uint8List.fromList(raw.sublist(2, dst + 2));
      destHash = Uint8List.fromList(raw.sublist(dst + 2, 2 * dst + 2));
      context = raw[2 * dst + 2];
      body = Uint8List.fromList(raw.sublist(2 * dst + 3));
    } else {
      if (raw.length < 2 + dst + 1) {
        throw PacketException('Malformed HEADER_1 packet');
      }
      destHash = Uint8List.fromList(raw.sublist(2, dst + 2));
      context = raw[dst + 2];
      body = Uint8List.fromList(raw.sublist(dst + 3));
    }
    if (body.isEmpty) throw PacketException('Zero-length data field');
    return Packet(
      destinationHash: destHash,
      data: body,
      packetType: packetType,
      context: context,
      headerType: headerType,
      contextFlag: contextFlag,
      transportType: transportType,
      destinationType: destinationType,
      hops: hops,
      transportId: transportId,
    );
  }

  /// Like [Packet.unpack] but returns null instead of throwing.
  static Packet? tryUnpack(List<int> raw) {
    try {
      return Packet.unpack(raw);
    } on PacketException {
      return null;
    }
  }

  /// The part of the packet covered by the packet hash: the low nibble of
  /// the flags plus everything after the hop count (and, for HEADER_2, after
  /// the transport id), so the hash is invariant under transport re-wrapping
  /// (Packet.get_hashable_part, Packet.py:350).
  Uint8List get hashablePart {
    final raw = pack();
    final b = BytesBuilder(copy: false)..addByte(raw[0] & 0x0F);
    b.add(
      headerType == header2
          ? Uint8List.sublistView(raw, truncatedHashLength + 2)
          : Uint8List.sublistView(raw, 2),
    );
    return b.toBytes();
  }

  /// Full SHA-256 packet hash.
  Uint8List get packetHash => sha256(hashablePart);

  /// Truncated (16 byte) packet hash, used as proof destination.
  Uint8List get truncatedPacketHash =>
      Uint8List.sublistView(packetHash, 0, truncatedHashLength);
}
