import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kestrel_rns/kestrel_rns.dart';

/// Where secrets live. The production implementation is the platform keystore
/// (`flutter_secure_storage`); tests use [MemorySecretStore].
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SecureSecretStore implements SecretStore {
  SecureSecretStore([FlutterSecureStorage? s])
    : _s =
          s ??
          const FlutterSecureStorage(
            // Unsigned macOS builds have no keychain-access-groups
            // entitlement, so the data-protection keychain fails (-34018);
            // use the file-based login keychain instead.
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );
  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _s.write(key: key, value: value);
}

class MemorySecretStore implements SecretStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;
}

/// Identity B (the phone): generated on first launch, private key stored only
/// in the [SecretStore]. Never written to the database or to logs.
class IdentityStore {
  IdentityStore(this.secrets);
  final SecretStore secrets;

  static const _key = 'kestrel.identity_b.private_key';

  Future<Identity> loadOrCreate() async {
    final existing = await secrets.read(_key);
    if (existing != null && existing.isNotEmpty) {
      return Identity.fromPrivateKey(base64.decode(existing));
    }
    final id = await Identity.generate();
    await secrets.write(_key, base64.encode(id.privateKey!));
    return id;
  }
}
