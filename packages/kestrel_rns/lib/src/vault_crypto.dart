import 'dart:convert';
import 'dart:typed_data';

import 'crypto/hashes.dart';
import 'crypto/random.dart';
import 'crypto/token.dart';
import 'identity.dart';
import 'msgpack/msgpack.dart';

/// Thrown when a vault blob or key chain is malformed or fails verification.
class VaultCryptoException implements Exception {
  VaultCryptoException(this.message);
  final String message;
  @override
  String toString() => 'VaultCryptoException: $message';
}

/// A decrypted, verified vault blob (docs/bridge-protocol.md section 9.4).
class VaultBlobPlain {
  VaultBlobPlain({
    required this.blobId,
    required this.deviceId,
    required this.seq,
    required this.keyEpoch,
    required this.kind,
    required this.ts,
    required this.data,
  });

  final String blobId;
  final String deviceId;
  final int seq;
  final int keyEpoch;
  final String kind;
  final double ts;
  final Object? data;
}

/// Client-side crypto envelope of the bridge vault (protocol section 9.4):
/// group-key chains, wrapping to an identity or an invite secret, per-epoch
/// keys and blob encryption. Byte-compatible with Python RNS 1.6.1.
class VaultCrypto {
  VaultCrypto._();

  static final Uint8List _salt = Uint8List.fromList(utf8.encode('kestrel-vault-v1'));

  /// Fresh random 32-byte group key (never derived from an older key).
  static Uint8List generateGroupKey({RandomBytes? random}) =>
      (random ?? secureRandomBytes)(32);

  // ---- key chain ------------------------------------------------------------

  /// msgpack `{"v": 1, "keys": {"<epoch>": bin(32)}}`, epochs ascending.
  static Uint8List packChain(Map<int, Uint8List> keys) {
    final epochs = keys.keys.toList()..sort();
    return packb({
      'v': 1,
      'keys': {for (final e in epochs) '$e': keys[e]!},
    });
  }

  static Map<int, Uint8List> unpackChain(List<int> bytes) {
    final Object? o;
    try {
      o = unpackb(bytes);
    } on Object catch (e) {
      throw VaultCryptoException('key chain is not msgpack: $e');
    }
    if (o is! Map || o['v'] != 1 || o['keys'] is! Map) {
      throw VaultCryptoException('malformed key chain');
    }
    final out = <int, Uint8List>{};
    for (final e in (o['keys'] as Map).entries) {
      final epoch = e.key is String ? int.tryParse(e.key as String) : null;
      final v = e.value;
      if (epoch == null || epoch < 1 || v is! Uint8List || v.length != 32) {
        throw VaultCryptoException('malformed key chain entry');
      }
      out[epoch] = v;
    }
    if (out.isEmpty) throw VaultCryptoException('empty key chain');
    return out;
  }

  // ---- wrapping -------------------------------------------------------------

  /// `Identity.encrypt` of the packed chain to [target].
  static Future<Uint8List> wrapToIdentity(
    Map<int, Uint8List> chain,
    Identity target, {
    List<int>? ephemeralPrivate,
    List<int>? iv,
  }) =>
      target.encrypt(packChain(chain),
          ephemeralPrivate: ephemeralPrivate, iv: iv);

  /// Returns null when [wrapped] was not made for [me] or is corrupt.
  static Future<Map<int, Uint8List>?> unwrapFromIdentity(
    List<int> wrapped,
    Identity me,
  ) async {
    final plain = await me.decrypt(wrapped);
    if (plain == null) return null;
    try {
      return unpackChain(plain);
    } on VaultCryptoException {
      return null;
    }
  }

  /// `K_inv = HKDF-SHA256(64, ikm=invite_secret, salt="kestrel-vault-v1", info="invite")`.
  static Uint8List inviteKey(List<int> inviteSecret) => hkdf(
        length: 64,
        deriveFrom: inviteSecret,
        salt: _salt,
        context: utf8.encode('invite'),
      );

  static Future<Uint8List> wrapToInvite(
    Map<int, Uint8List> chain,
    List<int> inviteSecret, {
    List<int>? iv,
  }) =>
      Token(inviteKey(inviteSecret)).encrypt(packChain(chain), iv: iv);

  static Future<Map<int, Uint8List>?> unwrapFromInvite(
    List<int> wrapped,
    List<int> inviteSecret,
  ) async {
    try {
      final plain = await Token(inviteKey(inviteSecret)).decrypt(wrapped);
      return unpackChain(plain);
    } on Object {
      return null;
    }
  }

  // ---- blobs ----------------------------------------------------------------

  /// `K = HKDF-SHA256(64, ikm=GK_epoch, salt="kestrel-vault-v1", info="epoch:<n>")`.
  static Uint8List epochKey(List<int> groupKey, int epoch) => hkdf(
        length: 64,
        deriveFrom: groupKey,
        salt: _salt,
        context: utf8.encode('epoch:$epoch'),
      );

  /// Serialises and encrypts a blob with the key of [keyEpoch].
  static Future<Uint8List> encryptBlob({
    required Uint8List groupKey,
    required String blobId,
    required String deviceId,
    required int seq,
    required int keyEpoch,
    required String kind,
    required double ts,
    required Object? data,
    List<int>? iv,
  }) {
    final plain = packb({
      'v': 1,
      'blob_id': blobId,
      'device_id': deviceId,
      'seq': seq,
      'key_epoch': keyEpoch,
      'kind': kind,
      'ts': ts,
      'data': data,
    });
    return Token(epochKey(groupKey, keyEpoch)).encrypt(plain, iv: iv);
  }

  /// Decrypts [ciphertext] with the chain and checks the inner metadata
  /// against the outer one (Token has no associated data). Throws
  /// [VaultCryptoException] on any failure.
  static Future<VaultBlobPlain> decryptBlob({
    required Uint8List ciphertext,
    required Map<int, Uint8List> chain,
    required String blobId,
    required String deviceId,
    required int seq,
    required int keyEpoch,
  }) async {
    final gk = chain[keyEpoch];
    if (gk == null) throw VaultCryptoException('no key for epoch $keyEpoch');
    final Uint8List plain;
    try {
      plain = await Token(epochKey(gk, keyEpoch)).decrypt(ciphertext);
    } on Object catch (e) {
      throw VaultCryptoException('blob does not decrypt: $e');
    }
    final Object? o;
    try {
      o = unpackb(plain);
    } on Object catch (e) {
      throw VaultCryptoException('blob is not msgpack: $e');
    }
    if (o is! Map || o['v'] != 1) throw VaultCryptoException('malformed blob');
    if (o['blob_id'] != blobId ||
        o['device_id'] != deviceId ||
        o['seq'] != seq ||
        o['key_epoch'] != keyEpoch) {
      throw VaultCryptoException('blob metadata does not match');
    }
    final kind = o['kind'];
    final ts = o['ts'];
    if (kind is! String || ts is! num) {
      throw VaultCryptoException('malformed blob');
    }
    return VaultBlobPlain(
      blobId: blobId,
      deviceId: deviceId,
      seq: seq,
      keyEpoch: keyEpoch,
      kind: kind,
      ts: ts.toDouble(),
      data: o['data'],
    );
  }
}
