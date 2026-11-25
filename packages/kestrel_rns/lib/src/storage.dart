import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crypto/hashes.dart';

/// Persistence abstraction for the network layer: known destinations,
/// own-destination ratchets and announce stamps. Values are JSON maps so any
/// backend (files, SQLite, secure storage) can implement it trivially.
abstract class KestrelStorage {
  Future<Map<String, Object?>?> read(String key);
  Future<void> write(String key, Map<String, Object?> value);
  Future<void> delete(String key);
}

/// Non-persistent storage (tests, ephemeral nodes).
class MemoryStorage implements KestrelStorage {
  final Map<String, String> _data = {};

  @override
  Future<Map<String, Object?>?> read(String key) async {
    final v = _data[key];
    return v == null ? null : json.decode(v) as Map<String, Object?>;
  }

  @override
  Future<void> write(String key, Map<String, Object?> value) async {
    _data[key] = json.encode(value);
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }
}

/// One JSON file per key under [directory]. Writes are atomic (temp file +
/// rename). Keys may contain `/`, which maps to sub-directories.
///
/// NOTE: own-destination ratchet private keys are stored here in clear text;
/// apps should point this at a protected directory (or provide a
/// [KestrelStorage] backed by the platform keystore).
class JsonFileStorage implements KestrelStorage {
  JsonFileStorage(this.directory);
  final Directory directory;

  File _file(String key) {
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_./-]'), '_');
    return File('${directory.path}/$safe.json');
  }

  @override
  Future<Map<String, Object?>?> read(String key) async {
    final f = _file(key);
    if (!await f.exists()) return null;
    try {
      return json.decode(await f.readAsString()) as Map<String, Object?>;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String key, Map<String, Object?> value) async {
    final f = _file(key);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(json.encode(value), flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> delete(String key) async {
    final f = _file(key);
    if (await f.exists()) await f.delete();
  }
}

/// A destination learned from an announce (Identity.known_destinations,
/// Identity.py:109).
class KnownDestination {
  KnownDestination({
    required this.destinationHash,
    required this.publicKey,
    required this.timestamp,
    required this.packetHash,
    this.appData,
    this.ratchet,
    this.stampValue,
    this.linkCost,
  });

  final Uint8List destinationHash;
  final Uint8List publicKey;

  /// Seconds since epoch of the last announce.
  double timestamp;
  Uint8List packetHash;

  /// app_data with a valid stamp ext payload stripped.
  Uint8List? appData;

  /// Latest announced ratchet public key (Identity.known_ratchets).
  Uint8List? ratchet;
  double? stampValue;
  double? linkCost;

  Uint8List get identityHash => truncatedHash(publicKey);

  Map<String, Object?> toJson() => {
        'd': base64.encode(destinationHash),
        'k': base64.encode(publicKey),
        't': timestamp,
        'p': base64.encode(packetHash),
        if (appData != null) 'a': base64.encode(appData!),
        if (ratchet != null) 'r': base64.encode(ratchet!),
        if (stampValue != null) 'sv': stampValue,
        if (linkCost != null) 'lc': linkCost,
      };

  static KnownDestination fromJson(Map<String, Object?> j) => KnownDestination(
        destinationHash: base64.decode(j['d']! as String),
        publicKey: base64.decode(j['k']! as String),
        timestamp: (j['t']! as num).toDouble(),
        packetHash: base64.decode(j['p']! as String),
        appData: j['a'] == null ? null : base64.decode(j['a']! as String),
        ratchet: j['r'] == null ? null : base64.decode(j['r']! as String),
        stampValue: (j['sv'] as num?)?.toDouble(),
        linkCost: (j['lc'] as num?)?.toDouble(),
      );
}
