import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;

import 'hashes.dart';
import 'random.dart';

/// Thrown when a token cannot be authenticated or decrypted.
class TokenException implements Exception {
  TokenException(this.message);
  final String message;
  @override
  String toString() => 'TokenException: $message';
}

/// RNS "Token": a Fernet-like AES-CBC + HMAC-SHA256 construction without the
/// version/timestamp fields (RNS/Cryptography/Token.py).
///
/// Wire format: `IV(16) || AES-CBC(PKCS7(plaintext)) || HMAC-SHA256(IV||ct)`.
/// 32-byte keys select AES-128 (`signing=key[:16]`, `enc=key[16:]`), 64-byte
/// keys AES-256 (`signing=key[:32]`, `enc=key[32:]`) (Token.py:51-62).
class Token {
  Token(List<int> key) : this._(_split(key));

  Token._((Uint8List, Uint8List) keys)
      : _signingKey = keys.$1,
        _encryptionKey = keys.$2;

  static const int tokenOverhead = 48;
  static const int _blockSize = 16;

  static (Uint8List, Uint8List) _split(List<int> key) {
    final k = Uint8List.fromList(key);
    if (k.length == 32) {
      return (Uint8List.sublistView(k, 0, 16), Uint8List.sublistView(k, 16));
    }
    if (k.length == 64) {
      return (Uint8List.sublistView(k, 0, 32), Uint8List.sublistView(k, 32));
    }
    throw ArgumentError(
      'Token key must be 128 or 256 bits, not ${k.length * 8}',
    );
  }

  final Uint8List _signingKey;
  final Uint8List _encryptionKey;

  cg.AesCbc get _aes => _encryptionKey.length == 16
      ? cg.AesCbc.with128bits(
          macAlgorithm: cg.MacAlgorithm.empty,
          paddingAlgorithm: cg.PaddingAlgorithm.zero,
        )
      : cg.AesCbc.with256bits(
          macAlgorithm: cg.MacAlgorithm.empty,
          paddingAlgorithm: cg.PaddingAlgorithm.zero,
        );

  /// Random token key (Token.py `generate_key`).
  static Uint8List generateKey({bool aes256 = true, RandomBytes? random}) =>
      (random ?? secureRandomBytes)(aes256 ? 64 : 32);

  /// True if the trailing HMAC of [token] is valid (Token.py:64).
  bool verifyHmac(List<int> token) {
    if (token.length <= 32) {
      throw ArgumentError(
        'Cannot verify HMAC on token of only ${token.length} bytes',
      );
    }
    final body = token.sublist(0, token.length - 32);
    final received = token.sublist(token.length - 32);
    return constantTimeEquals(received, hmacSha256(_signingKey, body));
  }

  /// Encrypts [data]. [iv] (16 bytes) is only for deterministic tests;
  /// otherwise a fresh random IV is used.
  Future<Uint8List> encrypt(
    List<int> data, {
    List<int>? iv,
    RandomBytes? random,
  }) async {
    final ivBytes = Uint8List.fromList(iv ?? (random ?? secureRandomBytes)(16));
    if (ivBytes.length != 16) throw ArgumentError('IV must be 16 bytes');
    final padLen = _blockSize - data.length % _blockSize;
    final padded = Uint8List(data.length + padLen)
      ..setRange(0, data.length, data)
      ..fillRange(data.length, data.length + padLen, padLen);
    final box = await _aes.encrypt(
      padded,
      secretKey: cg.SecretKey(_encryptionKey),
      nonce: ivBytes,
    );
    final signed = (BytesBuilder(copy: false)
          ..add(ivBytes)
          ..add(box.cipherText))
        .toBytes();
    return (BytesBuilder(copy: false)
          ..add(signed)
          ..add(hmacSha256(_signingKey, signed)))
        .toBytes();
  }

  /// Verifies and decrypts [token].
  ///
  /// Padding handling mirrors RNS PKCS7.unpad (PKCS7.py:40-47): only the last
  /// byte is inspected (must be <= 16) and that many bytes are stripped; the
  /// padding bytes themselves are NOT verified.
  Future<Uint8List> decrypt(List<int> token) async {
    if (token.length <= 32) {
      throw TokenException(
        'Cannot verify HMAC on token of only ${token.length} bytes',
      );
    }
    if (!verifyHmac(token)) throw TokenException('Token HMAC was invalid');
    final iv = Uint8List.fromList(token.sublist(0, 16));
    final ct = Uint8List.fromList(token.sublist(16, token.length - 32));
    if (ct.isEmpty || ct.length % _blockSize != 0) {
      throw TokenException(
        'Could not decrypt token: invalid ciphertext length',
      );
    }
    final List<int> plain;
    try {
      plain = await _aes.decrypt(
        cg.SecretBox(ct, nonce: iv, mac: cg.Mac.empty),
        secretKey: cg.SecretKey(_encryptionKey),
      );
    } on Object catch (e) {
      throw TokenException('Could not decrypt token: $e');
    }
    final n = plain.last;
    if (n > _blockSize) {
      throw TokenException(
        'Could not decrypt token: invalid padding length of $n bytes',
      );
    }
    return Uint8List.fromList(plain.sublist(0, plain.length - n));
  }
}
