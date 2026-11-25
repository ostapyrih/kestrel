import 'dart:convert';
import 'dart:typed_data';

import 'crypto/hashes.dart';
import 'identity.dart';

/// Destination types (RNS/Destination.py:65-68). Values are the 2-bit wire
/// field in the packet flags.
abstract final class DestinationType {
  static const int single = 0x00;
  static const int group = 0x01;
  static const int plain = 0x02;
  static const int link = 0x03;
}

/// An RNS destination: name + aspects, optionally bound to an [Identity].
///
/// Hash derivation (Destination.py:118-133):
/// `name_hash = SHA256("app.aspect1.aspect2")[:10]`,
/// `hash = SHA256(name_hash || identity_hash)[:16]` (identity part omitted
/// for PLAIN destinations).
class Destination {
  Destination._({
    required this.type,
    required this.appName,
    required this.aspects,
    this.identity,
  })  : name = expandName(identity, appName, aspects),
        nameHash = nameHashFor(appName, aspects),
        hash = hashFor(identity, appName, aspects);

  /// SINGLE destination for [identity] (e.g. `lxmf.delivery`).
  factory Destination.single(
    Identity identity,
    String appName,
    List<String> aspects,
  ) =>
      Destination._(
        type: DestinationType.single,
        appName: appName,
        aspects: aspects,
        identity: identity,
      );

  /// PLAIN destination (no identity, no encryption).
  factory Destination.plain(String appName, List<String> aspects) =>
      Destination._(
        type: DestinationType.plain,
        appName: appName,
        aspects: aspects,
      );

  final int type;
  final String appName;
  final List<String> aspects;
  final Identity? identity;
  final String name;
  final Uint8List nameHash;
  final Uint8List hash;

  /// Human readable name, with the identity hex hash appended if given
  /// (Destination.expand_name, Destination.py:98).
  static String expandName(
    Identity? identity,
    String appName,
    List<String> aspects,
  ) {
    if (appName.contains('.')) {
      throw ArgumentError("Dots can't be used in app names");
    }
    final buf = StringBuffer(appName);
    for (final aspect in aspects) {
      if (aspect.contains('.')) {
        throw ArgumentError("Dots can't be used in aspects");
      }
      buf
        ..write('.')
        ..write(aspect);
    }
    if (identity != null) {
      buf
        ..write('.')
        ..write(_hex(identity.hash));
    }
    return buf.toString();
  }

  /// 10 byte name hash for `appName.aspects` (no identity).
  static Uint8List nameHashFor(String appName, List<String> aspects) {
    final full = expandName(null, appName, aspects);
    return Uint8List.sublistView(sha256(utf8.encode(full)), 0, 10);
  }

  /// Name hash for a dotted full name (Destination.name_hash).
  static Uint8List nameHashFromFullName(String fullName) =>
      Uint8List.sublistView(sha256(utf8.encode(fullName)), 0, 10);

  /// Destination hash. [identityOrHash] may be an [Identity], a 16 byte
  /// identity hash, or null (PLAIN).
  static Uint8List hashFor(
    Object? identityOrHash,
    String appName,
    List<String> aspects,
  ) {
    final material = BytesBuilder(copy: false)
      ..add(nameHashFor(appName, aspects));
    if (identityOrHash is Identity) {
      material.add(identityOrHash.hash);
    } else if (identityOrHash is List<int> && identityOrHash.length == 16) {
      material.add(identityOrHash);
    } else if (identityOrHash != null) {
      throw ArgumentError('Invalid material supplied for destination hash '
          'calculation');
    }
    return truncatedHash(material.toBytes());
  }

  /// Encrypts [plaintext] to this destination (Destination.encrypt).
  /// PLAIN destinations return the plaintext unchanged.
  Future<Uint8List> encrypt(
    List<int> plaintext, {
    List<int>? ratchet,
    List<int>? ephemeralPrivate,
    List<int>? iv,
  }) {
    if (type == DestinationType.plain) {
      return Future.value(Uint8List.fromList(plaintext));
    }
    final id = identity;
    if (type == DestinationType.single && id != null) {
      return id.encrypt(
        plaintext,
        ratchet: ratchet,
        ephemeralPrivate: ephemeralPrivate,
        iv: iv,
      );
    }
    throw UnsupportedError('Unsupported destination type for encrypt');
  }

  /// Decrypts a token addressed to this (inbound) destination.
  Future<Uint8List?> decrypt(
    List<int> ciphertext, {
    List<List<int>>? ratchets,
    bool enforceRatchets = false,
  }) {
    if (type == DestinationType.plain) {
      return Future.value(Uint8List.fromList(ciphertext));
    }
    final id = identity;
    if (type == DestinationType.single && id != null) {
      return id.decrypt(
        ciphertext,
        ratchets: ratchets,
        enforceRatchets: enforceRatchets,
      );
    }
    throw UnsupportedError('Unsupported destination type for decrypt');
  }

  @override
  String toString() => '<$name:${_hex(hash)}>';
}

String _hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
