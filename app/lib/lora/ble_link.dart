import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:kestrel_rns/kestrel_rns.dart';

import 'lora_model.dart';

/// The Nordic UART service the RNode firmware exposes over BLE (the same
/// UUIDs as `BLEConnection` in RNS/Interfaces/RNodeInterface.py). The host
/// writes to RX and receives notifications on TX.
final Guid nusService = Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
final Guid nusRx = Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E');
final Guid nusTx = Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E');

/// Scans for RNodes advertising the UART service. Emits the growing list.
Stream<List<LoraDevice>> scanBleRNodes({
  Duration timeout = const Duration(seconds: 8),
}) async* {
  if (!await FlutterBluePlus.isSupported) {
    yield const [];
    return;
  }
  await FlutterBluePlus.startScan(withServices: [nusService], timeout: timeout);
  try {
    await for (final results in FlutterBluePlus.scanResults) {
      yield [
        for (final r in results)
          LoraDevice(
            LoraKind.ble,
            r.device.remoteId.str,
            r.advertisementData.advName.isNotEmpty
                ? r.advertisementData.advName
                : (r.device.platformName.isNotEmpty
                      ? r.device.platformName
                      : r.device.remoteId.str),
            detail: '${r.rssi} dBm',
          ),
      ];
      if (!FlutterBluePlus.isScanningNow) break;
    }
  } finally {
    await FlutterBluePlus.stopScan();
  }
}

/// RNode over BLE (Nordic UART). RNode firmware requires an encrypted,
/// bonded connection: the first connection makes the OS ask for the PIN the
/// RNode shows on its display (put it in pairing mode first). On Android the
/// bond is requested explicitly; iOS pairs on first access to the encrypted
/// characteristics.
class BleRNodeLink implements RNodeLink {
  BleRNodeLink._(this._device, this._rx);

  final BluetoothDevice _device;
  final BluetoothCharacteristic _rx;
  final _data = StreamController<Uint8List>();
  final _closed = Completer<void>();
  StreamSubscription<Object?>? _valueSub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;

  static Future<RNodeLink> open(String remoteId, String name) async {
    final device = BluetoothDevice.fromId(remoteId);
    await device.connect(timeout: const Duration(seconds: 15), mtu: 247);
    try {
      if (Platform.isAndroid) {
        try {
          await device.createBond(timeout: 60);
        } on Object {
          // already bonded, or the user dismissed the dialog: the
          // characteristic access below fails with a clear error if needed
        }
      }
      final services = await device.discoverServices();
      final svc = services.firstWhere(
        (s) => s.uuid == nusService,
        orElse: () => throw StateError('not an RNode (no UART service)'),
      );
      final rx = svc.characteristics.firstWhere((c) => c.uuid == nusRx);
      final tx = svc.characteristics.firstWhere((c) => c.uuid == nusTx);
      final link = BleRNodeLink._(device, rx);
      link._valueSub = tx.onValueReceived.listen(
        (v) => link._data.add(Uint8List.fromList(v)),
      );
      link._stateSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) link._finish();
      });
      await tx.setNotifyValue(true);
      return link;
    } on Object {
      await device.disconnect();
      rethrow;
    }
  }

  @override
  String get description => _device.platformName.isNotEmpty
      ? _device.platformName
      : _device.remoteId.str;

  @override
  Stream<Uint8List> get received => _data.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> write(Uint8List bytes) async {
    // the characteristic carries at most MTU - 3 bytes per write
    final chunk = (_device.mtuNow - 3).clamp(20, 512);
    for (var i = 0; i < bytes.length; i += chunk) {
      final end = i + chunk > bytes.length ? bytes.length : i + chunk;
      await _rx.write(bytes.sublist(i, end), withoutResponse: true);
    }
  }

  void _finish() {
    if (_closed.isCompleted) return;
    _closed.complete();
    unawaited(_valueSub?.cancel());
    unawaited(_stateSub?.cancel());
    unawaited(_data.close());
  }

  @override
  Future<void> close() async {
    try {
      await _device.disconnect();
    } on Object {
      // already gone
    }
    _finish();
  }
}
