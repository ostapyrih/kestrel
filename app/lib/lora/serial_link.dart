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
      final desc = [
        p.productName,
        p.manufacturer,
        p.description,
      ].whereType<String>().where((s) => s.isNotEmpty).toSet().join(' · ');
      out.add(LoraDevice(LoraKind.usb, name, name, detail: desc));
    } finally {
      p.dispose();
    }
  }
  return out;
}

/// RNode over a USB serial port: 115200 baud, 8N1, no flow control, as in
/// RNodeInterface.open_port.
class SerialRNodeLink implements RNodeLink {
  SerialRNodeLink._(this._port, this._reader, this.portName);

  final SerialPort _port;
  final SerialPortReader _reader;
  final String portName;
  final _data = StreamController<Uint8List>();
  final _closed = Completer<void>();
  StreamSubscription<Uint8List>? _sub;
  Timer? _watch;

  static Future<RNodeLink> open(String name) async {
    final port = SerialPort(name);
    if (!port.openReadWrite()) {
      final err = SerialPort.lastError;
      port.dispose();
      throw StateError('could not open $name: ${err ?? 'unknown error'}');
    }
    final cfg = SerialPortConfig()
      ..baudRate = 115200
      ..bits = 8
      ..parity = SerialPortParity.none
      ..stopBits = 1
      ..setFlowControl(SerialPortFlowControl.none);
    port.config = cfg;
    cfg.dispose();
    final link = SerialRNodeLink._(port, SerialPortReader(port), name);
    link._sub = link._reader.stream.listen(
      link._data.add,
      onError: (Object _) => link._finish(),
      onDone: link._finish,
    );
    // an unplugged adapter does not always end the reader: poll the port list
    link._watch = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!SerialPort.availablePorts.contains(name)) link._finish();
    });
    return link;
  }

  @override
  String get description => portName;

  @override
  Stream<Uint8List> get received => _data.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> write(Uint8List bytes) async {
    if (_closed.isCompleted) throw StateError('port closed');
    final n = _port.write(bytes);
    if (n != bytes.length) {
      _finish();
      throw StateError('short write to $portName');
    }
  }

  bool _done = false;
  void _finish() {
    if (_done) return;
    _done = true;
    _watch?.cancel();
    unawaited(_sub?.cancel());
    _reader.close();
    try {
      _port.close();
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
