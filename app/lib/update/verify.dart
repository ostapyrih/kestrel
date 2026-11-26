import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' as cg;

import 'release_key.dart';

enum VerifyFailure { badSignature, notListed, checksumMismatch }

class UpdateVerifyException implements Exception {
  UpdateVerifyException(this.failure, [this.detail = '']);

  final VerifyFailure failure;
  final String detail;

  @override
  String toString() => 'UpdateVerifyException(${failure.name}: $detail)';
}

/// Verifies the Ed25519 [signatureB64] (base64 of the raw 64-byte signature)
/// over the exact bytes of `SHA256SUMS.txt`. Throws [UpdateVerifyException].
Future<void> verifySumsSignature(
  List<int> sums,
  String signatureB64, {
  String publicKeyB64 = releasePublicKeyB64,
}) async {
  try {
    final sig = base64.decode(signatureB64.trim());
    final pub = base64.decode(publicKeyB64);
    if (sig.length != 64 || pub.length != 32) {
      throw UpdateVerifyException(VerifyFailure.badSignature, 'bad length');
    }
    final ok = await cg.Ed25519().verify(
      sums,
      signature: cg.Signature(
        sig,
        publicKey: cg.SimplePublicKey(pub, type: cg.KeyPairType.ed25519),
      ),
    );
    if (!ok) throw UpdateVerifyException(VerifyFailure.badSignature);
  } on FormatException catch (e) {
    throw UpdateVerifyException(VerifyFailure.badSignature, e.message);
  }
}

/// `sha256sum` output: `<hex>  <name>` per line.
Map<String, String> parseSums(String text) {
  final out = <String, String>{};
  for (final line in const LineSplitter().convert(text)) {
    final m = RegExp(r'^([0-9a-fA-F]{64}) [ *](.+)$').firstMatch(line.trim());
    if (m != null) out[m[2]!] = m[1]!.toLowerCase();
  }
  return out;
}

/// Checks that [assetName] is listed in the sums and that [actualSha256Hex]
/// matches. Call only with sums whose signature has been verified.
void verifyAssetDigest(
  Map<String, String> sums,
  String assetName,
  String actualSha256Hex,
) {
  final expected = sums[assetName];
  if (expected == null) {
    throw UpdateVerifyException(VerifyFailure.notListed, assetName);
  }
  if (expected != actualSha256Hex.toLowerCase()) {
    throw UpdateVerifyException(VerifyFailure.checksumMismatch, assetName);
  }
}

Future<String> sha256OfFile(File f) async =>
    (await crypto.sha256.bind(f.openRead()).first).toString();
