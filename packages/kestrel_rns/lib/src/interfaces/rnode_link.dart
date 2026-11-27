import 'dart:async';
import 'dart:typed_data';

/// A raw byte pipe to an RNode: a serial port, a BLE UART characteristic pair
/// or a test double. [RNodeInterface] speaks KISS over it; the link knows
/// nothing about framing. No Flutter dependency lives here: the app provides
/// the BLE / USB implementations.
abstract class RNodeLink {
  /// Human readable description (port name, BLE device name), for status.
  String get description;

  /// Bytes arriving from the device, in order, in arbitrary chunks.
  Stream<Uint8List> get received;

  /// Writes [bytes] to the device. Completes when handed to the OS; throws
  /// if the link is gone.
  Future<void> write(Uint8List bytes);

  /// Completes (once) when the link is lost or closed, from either side.
  Future<void> get closed;

  /// Closes the link. Idempotent.
  Future<void> close();
}

/// Opens a new [RNodeLink] to the (already chosen) device; throws on failure.
/// Called again for every reconnect attempt.
typedef RNodeLinkOpener = Future<RNodeLink> Function();
