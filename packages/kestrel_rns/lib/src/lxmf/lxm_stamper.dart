import 'dart:isolate';
import 'dart:typed_data';

import '../crypto/hashes.dart';
import '../msgpack/msgpack.dart';
import '../stamps.dart';

/// LXMF message stamps (LXMF/LXStamper.py on top of RNS/Stamps.py).
///
/// A stamp is a 32 byte value such that `SHA256(workblock || stamp)` is below
/// the target for the receiver's required cost. For message stamps the
/// workblock is `WORKBLOCK_EXPAND_ROUNDS` (3000) HKDF chunks of 256 bytes
/// derived from the message id (a 768 kB buffer), so generation and
/// validation run on a background isolate.
abstract final class LxmStamper {
  static const int workblockExpandRounds = 3000;
  static const int expandChunk = 256;
  static const int stampSize = 32;

  /// `stamp_workblock(material, expand_rounds)` (Stamps.py:_stamp_workblock).
  static Uint8List workblock(
    List<int> material, {
    int expandRounds = workblockExpandRounds,
  }) {
    if (expandRounds <= 0) return Uint8List.fromList(material);
    final out = BytesBuilder(copy: false);
    for (var n = 0; n < expandRounds; n++) {
      out.add(hkdf(
        length: expandChunk,
        deriveFrom: material,
        salt: sha256([...material, ...packb(n)]),
      ));
    }
    return out.toBytes();
  }

  /// Synchronous validity check: first the non-expanded workblock
  /// (transitional mechanism in LXMessage.validate_stamp), then the expanded
  /// one. Returns the stamp value, or null if the stamp does not reach [cost].
  static double? validateSync(
    List<int> stamp,
    double cost,
    List<int> messageId,
  ) {
    if (Stamps.isValid(stamp, cost, messageId)) {
      return Stamps.value(messageId, stamp);
    }
    final wb = workblock(messageId);
    if (Stamps.isValid(stamp, cost, wb)) return Stamps.value(wb, stamp);
    return null;
  }

  /// [validateSync] on a background isolate.
  static Future<double?> validate(
    List<int> stamp,
    double cost,
    List<int> messageId,
  ) {
    final s = Uint8List.fromList(stamp);
    final m = Uint8List.fromList(messageId);
    return Isolate.run(() => validateSync(s, cost, m));
  }

  /// Generates a stamp of at least [cost] for [messageId] synchronously.
  static ({Uint8List stamp, double value}) generateSync(
    List<int> messageId,
    double cost,
  ) {
    final wb = workblock(messageId);
    final s = Stamps.generate(wb, cost, size: stampSize)!;
    return (stamp: s, value: Stamps.value(wb, s));
  }

  /// [generateSync] on a background isolate (`LXStamper.generate_stamp`).
  static Future<({Uint8List stamp, double value})> generate(
    List<int> messageId,
    double cost,
  ) {
    final m = Uint8List.fromList(messageId);
    return Isolate.run(() => generateSync(m, cost));
  }

  /// Ticket stamp (LXMessage.get_stamp with an outbound ticket).
  static Uint8List ticketStamp(List<int> ticket, List<int> messageId) =>
      truncatedHash([...ticket, ...messageId]);
}
