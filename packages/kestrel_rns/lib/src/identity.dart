import 'dart:typed_data';

import 'crypto/curves.dart';
import 'crypto/hashes.dart';
import 'crypto/random.dart';
import 'crypto/token.dart';

/// An RNS identity: an X25519 (encryption) + Ed25519 (signing) key pair.
///
/// Mirrors RNS/Identity.py. Private key serialisation is
/// `x25519_private(32) || ed25519_seed(32)` (Identity.py:1103), public key
/// `x25519_public(32) || ed25519_public(32)` (Identity.py:1110); the identity
/// hash is the truncated SHA-256 of the public key (Identity.py:1166).
class Identity {
  Identity._({
    required this.x25519Public,
    required this.ed25519Public,
    this.x25519Private,
    this.ed25519Seed,
  }) : hash = truncatedHash([...x25519Public, ...ed25519Public]);

  /// Public key length in bytes (Identity.KEYSIZE // 8).
  static const int keySize = 64;

  /// Ratchet key length in bytes.
  static const int ratchetSize = 32;

  /// Name hash length in bytes.
  static const int nameHashLength = 10;

  /// Truncated hash length in bytes.
  static const int truncatedHashLength = 16;

  /// Signature length in bytes.
  static const int signatureLength = 64;

  /// Length of the HKDF output used to key a [Token] (Identity.py:98).
  static const int derivedKeyLength = 64;

  final Uint8List x25519Public;
  final Uint8List ed25519Public;
  final Uint8List? x25519Private;
  final Uint8List? ed25519Seed;

  /// Truncated (16 byte) identity hash.
  final Uint8List hash;

  bool get hasPrivateKey => x25519Private != null && ed25519Seed != null;

  /// 64 byte private key, or null if this is a public-only identity.
  Uint8List? get privateKey => hasPrivateKey
      ? Uint8List.fromList([...x25519Private!, ...ed25519Seed!])
      : null;

  /// 64 byte public key.
  Uint8List get publicKey =>
      Uint8List.fromList([...x25519Public, ...ed25519Public]);

  /// Generates a fresh identity.
  static Future<Identity> generate({RandomBytes? random}) {
    final r = random ?? secureRandomBytes;
    return fromPrivateKey([...r(32), ...r(32)]);
  }

  /// Loads a 64 byte private key (Identity.load_private_key).
  static Future<Identity> fromPrivateKey(List<int> privateKey) async {
    if (privateKey.length != keySize) {
      throw ArgumentError('Identity private key must be 64 bytes');
    }
    final x = Uint8List.fromList(privateKey.sublist(0, 32));
    final e = Uint8List.fromList(privateKey.sublist(32));
    return Identity._(
      x25519Public: await x25519PublicKey(x),
      ed25519Public: await ed25519PublicKey(e),
      x25519Private: x,
      ed25519Seed: e,
    );
  }

  /// Loads a 64 byte public key (Identity.load_public_key).
  factory Identity.fromPublicKey(List<int> publicKey) {
    if (publicKey.length != keySize) {
      throw ArgumentError('Identity public key must be 64 bytes');
    }
    return Identity._(
      x25519Public: Uint8List.fromList(publicKey.sublist(0, 32)),
      ed25519Public: Uint8List.fromList(publicKey.sublist(32)),
    );
  }

  /// Ed25519 signature over [message] (Identity.sign).
  Future<Uint8List> sign(List<int> message) {
    final seed = ed25519Seed;
    if (seed == null) {
      throw StateError('Signing failed because identity does not hold a '
          'private key');
    }
    return ed25519Sign(seed, message);
  }

  /// Verifies [signature] over [message] (Identity.validate).
  Future<bool> validate(List<int> signature, List<int> message) =>
      ed25519Verify(ed25519Public, signature, message);

  /// Encrypts [plaintext] to this identity (Identity.encrypt,
  /// Identity.py:1186): `ephemeral_pub(32) || Token(plaintext)`, key
  /// `HKDF(64, ECDH(ephemeral, target), salt=identity_hash, context=none)`
  /// where `target` is the [ratchet] public key if given, else the identity
  /// X25519 key.
  ///
  /// [ephemeralPrivate] and [iv] exist for deterministic tests only.
  Future<Uint8List> encrypt(
    List<int> plaintext, {
    List<int>? ratchet,
    List<int>? ephemeralPrivate,
    List<int>? iv,
    RandomBytes? random,
  }) async {
    final r = random ?? secureRandomBytes;
    final eph = ephemeralPrivate ?? r(32);
    final ephPub = await x25519PublicKey(eph);
    final shared = await x25519Exchange(eph, ratchet ?? x25519Public);
    final key = hkdf(
      length: derivedKeyLength,
      deriveFrom: shared,
      salt: hash,
    );
    final token = await Token(key).encrypt(plaintext, iv: iv, random: random);
    return (BytesBuilder(copy: false)
          ..add(ephPub)
          ..add(token))
        .toBytes();
  }

  Future<Uint8List> _decryptWith(
    List<int> privateKey,
    List<int> peerPub,
    List<int> ciphertext,
  ) async {
    final shared = await x25519Exchange(privateKey, peerPub);
    final key = hkdf(length: derivedKeyLength, deriveFrom: shared, salt: hash);
    return Token(key).decrypt(ciphertext);
  }

  /// Decrypts a token produced by [encrypt] (Identity.decrypt,
  /// Identity.py:1231). Returns null on any failure, like the reference.
  ///
  /// [ratchets] are private ratchet keys tried first; with
  /// [enforceRatchets] the identity key is never tried. [onRatchetId]
  /// receives the matching ratchet id (or null).
  Future<Uint8List?> decrypt(
    List<int> ciphertextToken, {
    List<List<int>>? ratchets,
    bool enforceRatchets = false,
    void Function(Uint8List? ratchetId)? onRatchetId,
  }) async {
    final prv = x25519Private;
    if (prv == null) {
      throw StateError('Decryption failed because identity does not hold a '
          'private key');
    }
    if (ciphertextToken.length <= 32) return null;
    final peerPub = ciphertextToken.sublist(0, 32);
    final body = ciphertextToken.sublist(32);
    Uint8List? plaintext;
    try {
      if (ratchets != null) {
        for (final ratchet in ratchets) {
          try {
            plaintext = await _decryptWith(ratchet, peerPub, body);
            onRatchetId?.call(ratchetId(await ratchetPublicBytes(ratchet)));
            break;
          } on Object {
            // try next ratchet
          }
        }
      }
      if (enforceRatchets && plaintext == null) {
        onRatchetId?.call(null);
        return null;
      }
      if (plaintext == null) {
        plaintext = await _decryptWith(prv, peerPub, body);
        onRatchetId?.call(null);
      }
    } on Object {
      onRatchetId?.call(null);
      return null;
    }
    return plaintext;
  }

  /// Full SHA-256.
  static Uint8List fullHash(List<int> data) => sha256(data);

  /// Truncated (16 byte) SHA-256.
  static Uint8List truncated(List<int> data) => truncatedHash(data);

  /// New random 32 byte ratchet private key (Identity._generate_ratchet).
  static Uint8List generateRatchet({RandomBytes? random}) =>
      (random ?? secureRandomBytes)(32);

  /// X25519 public key for a ratchet private key.
  static Future<Uint8List> ratchetPublicBytes(List<int> ratchetPrivate) =>
      x25519PublicKey(ratchetPrivate);

  /// Ratchet id: first 10 bytes of SHA-256 of the ratchet public key
  /// (Identity._get_ratchet_id, Identity.py:529).
  static Uint8List ratchetId(List<int> ratchetPublic) =>
      Uint8List.sublistView(sha256(ratchetPublic), 0, nameHashLength);
}
