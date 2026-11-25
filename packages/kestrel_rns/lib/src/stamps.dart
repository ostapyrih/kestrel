import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import 'crypto/hashes.dart';
import 'crypto/random.dart';
import 'stamps_table.dart';

/// Proof-of-work stamps as implemented by RNS 1.6.1 (RNS/Stamps.py).
///
/// A stamp is valid for `workblock` when `SHA256(workblock || stamp)`, read as
/// a 256-bit big-endian integer, is `<= target(cost)`. Costs are fixed point
/// with 8 fractional bits (Stamps.py:855-958), so `23.5` means roughly 2^23.5
/// expected hashes. Announce and path-request stamps use no workblock
/// expansion (`expand_rounds=0`): the workblock is the raw material.
abstract final class Stamps {
  /// Transport.STAMP_COST_CAP (Transport.py:198).
  static const double costCap = 100;

  /// Transport.DESTINATION_COST / DESTINATION_VALUE / PR_COST / PR_VALUE /
  /// LR_COST (Transport.py:200-204).
  static const double defaultDestinationCost = 23.5;
  static const double defaultDestinationValue = 25.0;
  static const double defaultPathRequestCost = 15.8;
  static const double defaultPathRequestValue = 15.8;
  static const double defaultLinkCost = 12.5;

  /// RNS.Identity.STAMPLENGTH.
  static const int stampLength = 14;

  static const int mantissaBits = 33;
  static const int costFpBits = 8;
  static const int costFp = 1 << costFpBits;

  /// `cost_to_fp` (Stamps.py:915): round half up, clamp to `[0, cap]`.
  static int costToFp(double cost) {
    final v = (cost * costFp + 0.5).floor();
    return max(0, min(v, (costCap * costFp).toInt()));
  }

  static double costFromFp(int fp) => fp / costFp;

  /// `quantize_cost`.
  static double quantizeCost(double cost) => costFromFp(costToFp(cost));

  /// Two bytes `[integer part, fractional part]` (Stamps.py:919).
  static Uint8List costToBytes(double cost) {
    final fp = costToFp(cost);
    return Uint8List.fromList([(fp >> costFpBits) & 0xFF, fp & 0xFF]);
  }

  static double costFromBytes(List<int> b) =>
      costFromFp((b[0] << costFpBits) | b[1]);

  /// `target_from_fp` (Stamps.py:937).
  static BigInt targetFromFp(int fp) {
    final i = (256 * costFp - fp) ~/ costFp;
    final f = (256 * costFp - fp) % costFp;
    return (BigInt.from(stampTab[f]) << i) >> mantissaBits;
  }

  static Uint8List _bigTo32(BigInt v) {
    final out = Uint8List(32);
    var x = v;
    final mask = BigInt.from(0xFF);
    for (var i = 31; i >= 0; i--) {
      out[i] = (x & mask).toInt();
      x >>= 8;
    }
    return out;
  }

  /// 32-byte big-endian target for [cost].
  /// Clamped to 2^256-1 (cost 0 accepts every hash).
  static Uint8List targetBytes(double cost) {
    final t = targetFromFp(costToFp(cost));
    if (t >= (BigInt.one << 256)) return Uint8List(32)..fillRange(0, 32, 0xFF);
    return _bigTo32(t);
  }

  static bool _leq(List<int> hash, List<int> target) {
    for (var i = 0; i < 32; i++) {
      if (hash[i] != target[i]) return hash[i] < target[i];
    }
    return true;
  }

  /// `stamp_valid` (Stamps.py:268).
  static bool isValid(List<int> stamp, double cost, List<int> workblock) {
    final h = sha256([...workblock, ...stamp]);
    return _leq(h, targetBytes(cost));
  }

  static BigInt _bytesToBig(List<int> b) {
    var v = BigInt.zero;
    for (final x in b) {
      v = (v << 8) | BigInt.from(x);
    }
    return v;
  }

  /// `stamp_value` (Stamps.py:181): fixed-point value of a stamp, floored onto
  /// the 1/256 grid.
  static double value(List<int> workblock, List<int> stamp) {
    final hn = _bytesToBig(sha256([...workblock, ...stamp]));
    if (hn == BigInt.zero) return 256;
    const nb = mantissaBits + 1;
    final bl = hn.bitLength;
    final lz = 256 - bl;
    final BigInt mn = bl > nb ? (hn >> (bl - nb)) : (hn << (nb - bl));
    // bisect_right(TAB, mn): number of entries <= mn.
    var lo = 0;
    var hi = stampTab.length;
    final mnInt = mn.toInt(); // < 2^34, fits
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (mnInt < stampTab[mid]) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    final fp = ((lz + 1) << costFpBits) - lo;
    return costFromFp(fp);
  }

  /// Searches for a stamp of at least [cost] for [workblock] (synchronous,
  /// CPU bound; use [generateAsync] from UI code). Returns null if
  /// [maxRounds] (when > 0) is exhausted.
  ///
  /// Candidate stamps are a random prefix followed by an incrementing 64-bit
  /// counter, which is as valid as Python's `os.urandom` per round but avoids
  /// a CSPRNG call per hash.
  static Uint8List? generate(
    List<int> workblock,
    double cost, {
    int size = stampLength,
    int maxRounds = 0,
    RandomBytes? random,
  }) {
    if (cost < 0 || cost > costCap) {
      throw ArgumentError('Invalid stamp cost, cannot generate');
    }
    final target = targetBytes(cost);
    final r = random ?? secureRandomBytes;
    final buf = Uint8List(workblock.length + size)
      ..setRange(0, workblock.length, workblock);
    final base = workblock.length;
    var rounds = 0;
    while (true) {
      // Fresh random prefix every 2^20 rounds, counter in the tail.
      final fresh = r(size);
      buf.setRange(base, base + size, fresh);
      for (var n = 0; n < (1 << 20); n++) {
        var k = base + size - 1;
        // increment counter (last up-to-8 bytes)
        final end = max(base, base + size - 8);
        while (k >= end) {
          buf[k] = (buf[k] + 1) & 0xFF;
          if (buf[k] != 0) break;
          k--;
        }
        final h = c.sha256.convert(buf).bytes;
        if (_leq(h, target)) {
          return Uint8List.fromList(buf.sublist(base));
        }
        rounds++;
        if (maxRounds != 0 && rounds >= maxRounds) return null;
      }
    }
  }

  /// [generate] on a background isolate so the UI isolate never blocks.
  static Future<Uint8List?> generateAsync(
    List<int> workblock,
    double cost, {
    int size = stampLength,
    int maxRounds = 0,
  }) {
    final wb = Uint8List.fromList(workblock);
    return Isolate.run(
      () => generate(wb, cost, size: size, maxRounds: maxRounds),
    );
  }

  /// Announce/destination stamp material (Destination.stamp_material,
  /// Destination.py:360): `dest_hash || public_key || name_hash`.
  static Uint8List destinationMaterial(
    List<int> destinationHash,
    List<int> publicKey,
    List<int> nameHash,
  ) =>
      Uint8List.fromList([...destinationHash, ...publicKey, ...nameHash]);

  /// Path request stamp material (Transport.pr_stamp_material).
  static Uint8List pathRequestMaterial(
          List<int> destinationHash, List<int> tag) =>
      Uint8List.fromList([...destinationHash, ...tag]);
}
