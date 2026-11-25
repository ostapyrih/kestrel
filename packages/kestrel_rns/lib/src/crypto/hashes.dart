import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

/// SHA-256 (RNS `Identity.full_hash`, RNS/Cryptography/Hashes.py).
Uint8List sha256(List<int> data) =>
    Uint8List.fromList(c.sha256.convert(data).bytes);

/// SHA-512.
Uint8List sha512(List<int> data) =>
    Uint8List.fromList(c.sha512.convert(data).bytes);

/// Truncated (128 bit) SHA-256 (RNS `Identity.truncated_hash`,
/// RNS/Identity.py:495).
Uint8List truncatedHash(List<int> data) =>
    Uint8List.sublistView(sha256(data), 0, 16);

/// HMAC-SHA256.
Uint8List hmacSha256(List<int> key, List<int> data) => Uint8List.fromList(
      c.Hmac(c.sha256, key).convert(data).bytes,
    );

/// Constant-time comparison of two byte lists.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// HKDF-SHA256 exactly as RNS/Cryptography/HKDF.py `hkdf()`.
///
/// An empty/absent [salt] is replaced with 32 zero bytes, an absent
/// [context] with the empty string (HKDF.py:41-42). The counter byte is the
/// RFC 5869 block index (1-based, wrapping at 256 like the reference).
Uint8List hkdf({
  required int length,
  required List<int> deriveFrom,
  List<int>? salt,
  List<int>? context,
}) {
  if (length < 1) throw ArgumentError.value(length, 'length');
  if (deriveFrom.isEmpty) {
    throw ArgumentError('Cannot derive key from empty input material');
  }
  final s = (salt == null || salt.isEmpty) ? Uint8List(32) : salt;
  final info = context ?? const <int>[];
  final prk = hmacSha256(s, deriveFrom);

  final out = BytesBuilder(copy: false);
  var block = Uint8List(0);
  final blocks = (length + 31) ~/ 32;
  for (var i = 0; i < blocks; i++) {
    final input = BytesBuilder(copy: false)
      ..add(block)
      ..add(info)
      ..addByte((i + 1) & 0xFF);
    block = hmacSha256(prk, input.toBytes());
    out.add(block);
  }
  return Uint8List.sublistView(out.toBytes(), 0, length);
}
