import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:kestrel_rns/kestrel_rns.dart';

import 'lora_model.dart';

/// Serial ports present now (USB RNodes show up as USB-serial ports).
List<LoraDevice> listSerialRNodePorts() {
  final out = <LoraDevice>[];
  for (final name in SerialPort.availablePorts) {
    final p = SerialPort(name);
    try {
      String desc = '';
      try {
        desc = [
          p.productName,
          p.manufacturer,
          p.description,
        ].whereType<String>().where((s) => s.isNotEmpty).toSet().join(' · ');
      } on Object {
        // some virtual/busy Windows COM ports fail metadata queries
      }
      out.add(LoraDevice(LoraKind.usb, name, name, detail: desc));
    } finally {
      p.dispose();
    }
  }
  return out;
}

/// RNode over a USB serial port: 115200 baud, 8N1, no flow control, as in
/// RNodeInterface.open_port.
///
/// Uses non-blocking single-isolate polling (`bytesAvailable` + `read`) instead
/// of `SerialPortReader`, because `SerialPortReader` spawns an Isolate holding
/// the raw `sp_port*` pointer and causes a native use-after-free crash on
/// Windows when the port is closed/disposed while `sp_wait` is blocked.
class SerialRNodeLink implements RNodeLink {
  SerialRNodeLink._(this._port, this.portName);

  final SerialPort _port;
  final String portName;
  final _data = StreamController<Uint8List>();
  final _closed = Completer<void>();
  Timer? _pollTimer;
  Timer? _watch;

  static Future<RNodeLink> open(String name) async {
    final port = SerialPort(name);
    try {
      if (!port.openReadWrite()) {
        final err = SerialPort.lastError;
        throw StateError('could not open $name: ${err ?? 'unknown error'}');
      }
      final cfg = port.config;
      try {
        cfg
          ..baudRate = 115200
          ..bits = 8
          ..parity = SerialPortParity.none
          ..stopBits = 1
          ..setFlowControl(SerialPortFlowControl.none);
        port.config = cfg;
      } finally {
        cfg.dispose();
      }
    } catch (e) {
      try {
        if (port.isOpen) port.close();
      } on Object {
        // ignore
      }
      port.dispose();
      rethrow;
    }

    final link = SerialRNodeLink._(port, name);
    link._pollTimer = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => link._poll(),
    );
    // an unplugged adapter does not always error immediately: poll the port list
    link._watch = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!SerialPort.availablePorts.contains(name)) link._finish();
    });
    return link;
  }

  void _poll() {
    if (_done) return;
    try {
      final avail = _port.bytesAvailable;
      if (avail < 0) {
        _finish();
        return;
      }
      if (avail == 0) return;
      final chunk = _port.read(avail, timeout: 0);
      if (chunk.isNotEmpty && !_data.isClosed) {
        _data.add(chunk);
      }
    } on Object {
      _finish();
    }
  }

  @override
  String get description => portName;

  @override
  Stream<Uint8List> get received => _data.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> write(Uint8List bytes) async {
    if (_done || _closed.isCompleted) throw StateError('port closed');
    try {
      final n = _port.write(bytes);
      if (n != bytes.length) {
        _finish();
        throw StateError('short write to $portName');
      }
    } on Object {
      _finish();
      rethrow;
    }
  }

  bool _done = false;
  void _finish() {
    if (_done) return;
    _done = true;
    _pollTimer?.cancel();
    _watch?.cancel();
    try {
      if (_port.isOpen) _port.close();
    } on Object {
      // already closed
    }
    _port.dispose();
    if (!_closed.isCompleted) _closed.complete();
    unawaited(_data.close());
  }

  @override
  Future<void> close() async => _finish();
}
