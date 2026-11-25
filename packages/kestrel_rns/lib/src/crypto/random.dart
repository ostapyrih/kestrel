import 'dart:math';
import 'dart:typed_data';

/// Source of random bytes. Injectable so tests can make output deterministic.
typedef RandomBytes = Uint8List Function(int length);

final Random _secure = Random.secure();

/// Cryptographically secure random bytes (OS CSPRNG).
Uint8List secureRandomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _secure.nextInt(256);
  }
  return out;
}
