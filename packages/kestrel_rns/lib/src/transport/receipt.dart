import 'dart:async';
import 'dart:typed_data';

import '../crypto/hashes.dart';
import '../destination.dart';

/// Delivery state of a sent packet (PacketReceipt, Packet.py:437).
enum ReceiptStatus { failed, sent, delivered, culled }

/// Tracks the proof for a sent DATA packet.
///
/// A proof is either explicit (`packet_hash(32) || signature(64)`) or
/// implicit (`signature(64)`, the RNS default for SINGLE destinations); both
/// are signatures over the full packet hash by the destination identity (or,
/// on links, by the link's signing key) (Packet.py:validate_proof*).
class PacketReceipt {
  PacketReceipt({
    required this.hash,
    required this.destination,
    required this.timeout,
    this.linkValidator,
  })  : truncatedHash = Uint8List.sublistView(hash, 0, 16),
        sentAt = DateTime.now();

  final Uint8List hash;
  final Uint8List truncatedHash;
  final Destination? destination;

  /// For link packets: validates a signature over [hash].
  final Future<bool> Function(List<int> signature, List<int> message)?
      linkValidator;

  /// Seconds until the receipt is considered failed.
  double timeout;
  final DateTime sentAt;
  DateTime? concludedAt;
  ReceiptStatus status = ReceiptStatus.sent;

  final _done = Completer<PacketReceipt>();

  /// Completes (never with an error) when the packet is proved or timed out;
  /// check [status].
  Future<PacketReceipt> get done => _done.future;

  void Function(PacketReceipt)? onDelivered;
  void Function(PacketReceipt)? onTimedOut;

  bool get isTimedOut =>
      DateTime.now().difference(sentAt).inMicroseconds / 1e6 > timeout;

  Duration? get rtt => concludedAt?.difference(sentAt);

  void _conclude(ReceiptStatus s) {
    status = s;
    concludedAt = DateTime.now();
    if (!_done.isCompleted) _done.complete(this);
  }

  /// Checks [proofData] (PROOF packet payload); returns true if it proves this
  /// receipt and updates the status.
  Future<bool> validateProof(List<int> proofData,
      {required bool onLink}) async {
    if (status != ReceiptStatus.sent) return false;
    List<int> signature;
    if (onLink) {
      // Links always use explicit proofs (Packet.py:validate_link_proof).
      if (proofData.length < 96) return false;
      if (!constantTimeEquals(proofData.sublist(0, 32), hash)) return false;
      signature = proofData.sublist(32, 96);
      final v = linkValidator;
      if (v == null || !await v(signature, hash)) return false;
    } else {
      final id = destination?.identity;
      if (id == null) return false;
      if (proofData.length == 96) {
        if (!constantTimeEquals(proofData.sublist(0, 32), hash)) return false;
        signature = proofData.sublist(32, 96);
      } else if (proofData.length == 64) {
        signature = proofData;
      } else {
        return false;
      }
      if (!await id.validate(signature, hash)) return false;
    }
    _conclude(ReceiptStatus.delivered);
    onDelivered?.call(this);
    return true;
  }

  /// Called by the transport job when [isTimedOut].
  void expire() {
    if (status != ReceiptStatus.sent) return;
    _conclude(timeout == -1 ? ReceiptStatus.culled : ReceiptStatus.failed);
    onTimedOut?.call(this);
  }

  void cancel() {
    if (status == ReceiptStatus.sent) _conclude(ReceiptStatus.failed);
  }
}
