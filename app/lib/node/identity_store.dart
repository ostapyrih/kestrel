import 'dart:convert';
import 'dart:io';

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

  /// iOS background checks run while the phone is locked, when keychain items
  /// of the default accessibility ("when unlocked") cannot be read. Every
  /// secret is therefore mirrored under `<key>.bg` with "after first unlock".
  /// Existing items are never modified or deleted, only copied.
  static const _bgSuffix = '.bg';
  static const _bgOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );
  bool get _mirror => Platform.isIOS;

  @override
  Future<String?> read(String key) async {
    if (!_mirror) return _s.read(key: key);
    try {
      final b = await _s.read(key: '$key$_bgSuffix', iOptions: _bgOptions);
      if (b != null && b.isNotEmpty) return b;
    } on Object {
      // fall through to the primary item
    }
    final v = await _s.read(key: key);
    if (v != null && v.isNotEmpty) await _writeMirror(key, v);
    return v;
  }

  @override
  Future<void> write(String key, String value) async {
    await _s.write(key: key, value: value);
    if (_mirror) await _writeMirror(key, value);
  }

  Future<void> _writeMirror(String key, String value) async {
    try {
      await _s.write(key: '$key$_bgSuffix', value: value, iOptions: _bgOptions);
    } on Object {
      // best effort: the background check just cannot run while locked
    }
  }
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
