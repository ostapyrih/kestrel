import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;

// Thin async wrappers over `package:cryptography` for the two curves RNS uses.
//
// `package:cryptography` is used (rather than pointycastle) because it
// provides pure-Dart X25519/Ed25519/AES-CBC that can later be swapped for
// native implementations via `cryptography_flutter` without touching this
// code. Hashes/HMAC use `package:crypto` (synchronous), see `hashes.dart`.

final cg.X25519 _x25519 = cg.X25519();
final cg.Ed25519 _ed25519 = cg.Ed25519();

/// X25519 public key for a 32-byte private key (RFC 7748 clamping applied by
/// the backend, like pyca/OpenSSL).
Future<Uint8List> x25519PublicKey(List<int> privateKey) async {
  final kp = await _x25519.newKeyPairFromSeed(privateKey);
  final pub = await kp.extractPublicKey();
  return Uint8List.fromList(pub.bytes);
}

/// X25519 shared secret. Throws [StateError] if the result is all-zero
/// (low-order peer point), matching pyca's rejection.
Future<Uint8List> x25519Exchange(
  List<int> privateKey,
  List<int> peerPublicKey,
) async {
  final kp = await _x25519.newKeyPairFromSeed(privateKey);
  final secret = await _x25519.sharedSecretKey(
    keyPair: kp,
    remotePublicKey: cg.SimplePublicKey(
      peerPublicKey,
      type: cg.KeyPairType.x25519,
    ),
  );
  final bytes = Uint8List.fromList(await secret.extractBytes());
  if (bytes.every((b) => b == 0)) {
    throw StateError('X25519 produced an all-zero shared secret');
  }
  return bytes;
}

/// Ed25519 public key for a 32-byte seed.
Future<Uint8List> ed25519PublicKey(List<int> seed) async {
  final kp = await _ed25519.newKeyPairFromSeed(seed);
  final pub = await kp.extractPublicKey();
  return Uint8List.fromList(pub.bytes);
}

/// Deterministic Ed25519 signature (RFC 8032).
Future<Uint8List> ed25519Sign(List<int> seed, List<int> message) async {
  final kp = await _ed25519.newKeyPairFromSeed(seed);
  final sig = await _ed25519.sign(message, keyPair: kp);
  return Uint8List.fromList(sig.bytes);
}

/// Ed25519 verification; never throws, returns false on malformed input.
Future<bool> ed25519Verify(
  List<int> publicKey,
  List<int> signature,
  List<int> message,
) async {
  if (publicKey.length != 32 || signature.length != 64) return false;
  try {
    return await _ed25519.verify(
      message,
      signature: cg.Signature(
        signature,
        publicKey: cg.SimplePublicKey(publicKey, type: cg.KeyPairType.ed25519),
      ),
    );
  } on Object {
    return false;
  }
}
