import 'dart:typed_data';

import '../util.dart';

/// A persisted outbound message (the queue entry of [LxmStore]).
///
/// [packed] is the fully packed, signed (and stamped) LXMF message, so a
/// restart can resume delivery without regenerating anything.
class LxmOutboundRecord {
  LxmOutboundRecord({
    required this.hash,
    required this.destinationHash,
    required this.packed,
    required this.desiredMethod,
    required this.createdAt,
    this.attempts = 0,
    this.state = 0x01,
    this.tag,
  });

  final Uint8List hash;
  final Uint8List destinationHash;
  Uint8List packed;

  /// `LxmfMethod` chosen by the caller (before size based upgrades).
  final int desiredMethod;
  final DateTime createdAt;
  int attempts;

  /// `LxmState.code`.
  int state;

  /// Opaque caller value (the app stores its outbox row id here).
  final String? tag;

  @override
  String toString() => 'LxmOutboundRecord(${toHex(hash)})';
}

/// Pluggable persistence for the router: outbound queue and inbound
/// de-duplication. The app provides a SQLite implementation.
abstract class LxmStore {
  /// Messages that were queued but not yet concluded.
  Future<List<LxmOutboundRecord>> loadOutbound();

  /// Inserts or updates [r] (called on queueing and on every state change).
  Future<void> saveOutbound(LxmOutboundRecord r);

  /// Called when the message left the queue (delivered, failed, cancelled).
  Future<void> removeOutbound(Uint8List hash);

  /// Atomically records an inbound message hash. Returns false if it was
  /// already seen (a duplicate that must not be delivered again).
  Future<bool> claimInbound(Uint8List hash);
}

/// Non-persistent [LxmStore].
class MemoryLxmStore implements LxmStore {
  final Map<String, LxmOutboundRecord> outbound = {};
  final Set<String> inbound = {};

  @override
  Future<List<LxmOutboundRecord>> loadOutbound() async =>
      outbound.values.toList();

  @override
  Future<void> saveOutbound(LxmOutboundRecord r) async =>
      outbound[toHex(r.hash)] = r;

  @override
  Future<void> removeOutbound(Uint8List hash) async =>
      outbound.remove(toHex(hash));

  @override
  Future<bool> claimInbound(Uint8List hash) async => inbound.add(toHex(hash));
}
