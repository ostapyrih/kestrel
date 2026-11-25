import 'dart:async';
import 'dart:typed_data';

/// Connection state of an [RnsInterface].
enum InterfaceState { offline, connecting, online }

/// A transport-level link to the Reticulum network: moves raw Reticulum
/// packets in and out (RNS/Interfaces/Interface.py). Framing (HDLC for TCP,
/// KISS for RNode) is the interface's job; consumers only see whole packets.
///
/// A future `RNodeBleInterface` (KISS over BLE) implements this same API.
abstract class RnsInterface {
  /// Human readable name, e.g. `TCPInterface[host:port]`.
  String get name;

  /// Maximum frame the medium carries; advertised as link MTU during link MTU
  /// discovery when [autoconfigureMtu] is true (Interface.HW_MTU).
  int get hwMtu;

  /// Whether link MTU may be raised to [hwMtu] (Interface.AUTOCONFIGURE_MTU).
  bool get autoconfigureMtu;

  /// Nominal bitrate in bit/s (TCP: BITRATE_GUESS).
  int get bitrate;

  /// Current state; [stateChanges] emits on every change.
  InterfaceState get state;
  Stream<InterfaceState> get stateChanges;

  bool get online => state == InterfaceState.online;

  /// Whole inbound Reticulum packets.
  Stream<Uint8List> get received;

  /// Starts connecting. Completes once the interface is set up (not
  /// necessarily connected).
  Future<void> start();

  /// Closes the interface permanently.
  Future<void> stop();

  /// Transmits one raw Reticulum packet. Returns false if offline.
  Future<bool> send(Uint8List raw);
}
