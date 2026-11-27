import 'dart:io';

import 'package:kestrel_rns/kestrel_rns.dart';

import 'ble_link.dart';
import 'lora_model.dart';
import 'serial_link.dart';

/// What the platform can do to reach an RNode; faked in tests.
abstract class LoraTransports {
  /// Transports usable here: BLE on Android/iOS, USB serial on desktop.
  Set<LoraKind> get supported;

  /// BLE scan results (a growing list until the scan ends).
  Stream<List<LoraDevice>> scanBle();

  /// Serial ports present now.
  List<LoraDevice> listUsb();

  /// Opens (and for BLE: bonds with) the chosen device; called again for
  /// every reconnect.
  Future<RNodeLink> open(LoraKind kind, String id, String name);

  /// Handshake delays suited to the transport.
  RNodeTiming timing(LoraKind kind) =>
      kind == LoraKind.ble ? const RNodeTiming.ble() : const RNodeTiming();
}

/// flutter_blue_plus (mobile) and flutter_libserialport (desktop).
class PluginLoraTransports extends LoraTransports {
  @override
  Set<LoraKind> get supported => {
    if (Platform.isAndroid || Platform.isIOS) LoraKind.ble,
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
      LoraKind.usb,
  };

  @override
  Stream<List<LoraDevice>> scanBle() => scanBleRNodes();

  @override
  List<LoraDevice> listUsb() => listSerialRNodePorts();

  @override
  Future<RNodeLink> open(LoraKind kind, String id, String name) =>
      kind == LoraKind.ble
      ? BleRNodeLink.open(id, name)
      : SerialRNodeLink.open(id);
}
