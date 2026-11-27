import 'dart:async';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';

/// A shared radio channel: whatever one emulated RNode transmits is received
/// by every other one tuned to the same frequency/bandwidth/SF/CR.
class FakeAir {
  final List<EmulatedRNode> nodes = [];

  /// Number of frames put on the air.
  int transmissions = 0;

  void _tx(EmulatedRNode from, Uint8List data) {
    transmissions++;
    for (final n in nodes) {
      if (identical(n, from) || !n.radioOn) continue;
      if (n.frequency != from.frequency ||
          n.bandwidth != from.bandwidth ||
          n.sf != from.sf ||
          n.cr != from.cr) {
        continue;
      }
      n.receiveFromAir(data, rssi: -80, snr: 6.5);
    }
  }
}

/// The firmware side of the RNode KISS protocol (detect, firmware version,
/// platform/MCU, config echo, radio state, data frames with RSSI/SNR,
/// READY flow control), usable as an [RNodeLink] opener.
class EmulatedRNode {
  EmulatedRNode({
    this.air,
    this.fwMajor = 1,
    this.fwMinor = 82,
    this.platform = Kiss.platformEsp32,
    this.flowControl = true,
    this.chunkSize,
  }) {
    air?.nodes.add(this);
  }

  final FakeAir? air;
  int fwMajor, fwMinor, platform;

  /// Send READY after each transmitted data frame (firmware >= 1.52).
  bool flowControl;

  /// Send READY on its own; tests turn it off and call [sendReady].
  bool autoReady = true;

  /// Deliver output in chunks of this size (null = one chunk per frame).
  int? chunkSize;

  // behaviour switches
  bool answerDetect = true;
  bool refuseSf = false;
  bool refuseBandwidth = false;

  // observable state
  int frequency = 0, bandwidth = 0, txPower = 0, sf = 0, cr = 0;
  bool radioOn = false;
  bool leaveReceived = false;
  bool framebufferOff = false;
  int opens = 0;
  final List<Uint8List> transmitted = [];
  final List<Uint8List> rawWrites = [];
  _EmuLink? _link;

  bool get connected => _link != null && !_link!._closed;

  /// An opener for [RNodeInterface]; every call is a new connection.
  Future<RNodeLink> open() async {
    opens++;
    _link?._drop();
    return _link = _EmuLink(this);
  }

  /// Simulates unplugging the device.
  void unplug() => _link?._drop();

  void _out(List<int> frame) {
    final l = _link;
    if (l == null || l._closed) return;
    final b = Uint8List.fromList(frame);
    final cs = chunkSize;
    if (cs == null) {
      l._rx.add(b);
    } else {
      for (var i = 0; i < b.length; i += cs) {
        l._rx.add(b.sublist(i, i + cs > b.length ? b.length : i + cs));
      }
    }
  }

  void _cmd(int command, List<int> payload) =>
      _out(Kiss.frame(payload, command: command));

  /// Emits a data frame the way the firmware does: RSSI, SNR, then data.
  void receiveFromAir(Uint8List data, {required int rssi, required double snr}) {
    _cmd(Kiss.cmdStatRssi, [rssi + RNodeInterface.rssiOffset]);
    _cmd(Kiss.cmdStatSnr, [(snr / 0.25).round() & 0xFF]);
    _out(Kiss.frame(data));
  }

  /// Emits raw bytes (e.g. a truncated frame).
  void emitRaw(List<int> bytes) => _out(bytes);

  void sendReady() => _cmd(Kiss.cmdReady, [0x01]);

  /// Emits an arbitrary frame (errors, channel time, ...).
  void emit(int command, List<int> payload) => _cmd(command, payload);

  // The firmware treats every FEND as "end of frame and start of the next",
  // so the host may share one FEND between frames (as the detect request
  // does); that is why this is not a KissDecoder.
  bool _inFrame = false, _esc = false;
  int _cmdByte = Kiss.cmdUnknown;
  final List<int> _buf = [];

  Iterable<KissFrame> _parse(Uint8List bytes) sync* {
    for (var b in bytes) {
      if (b == Kiss.fend) {
        if (_inFrame && _cmdByte != Kiss.cmdUnknown) {
          yield KissFrame(_cmdByte, Uint8List.fromList(_buf));
        }
        _inFrame = true;
        _cmdByte = Kiss.cmdUnknown;
        _buf.clear();
        _esc = false;
      } else if (_inFrame) {
        if (_cmdByte == Kiss.cmdUnknown) {
          _cmdByte = b;
        } else if (b == Kiss.fesc) {
          _esc = true;
        } else {
          if (_esc) {
            if (b == Kiss.tfend) b = Kiss.fend;
            if (b == Kiss.tfesc) b = Kiss.fesc;
            _esc = false;
          }
          _buf.add(b);
        }
      }
    }
  }

  void _hostWrote(Uint8List bytes) {
    rawWrites.add(bytes);
    for (final f in _parse(bytes)) {
      final d = f.data;
      switch (f.command) {
        case Kiss.cmdDetect:
          if (answerDetect) _cmd(Kiss.cmdDetect, [Kiss.detectResp]);
        case Kiss.cmdFwVersion:
          _cmd(Kiss.cmdFwVersion, [fwMajor, fwMinor]);
        case Kiss.cmdPlatform:
          _cmd(Kiss.cmdPlatform, [platform]);
        case Kiss.cmdMcu:
          _cmd(Kiss.cmdMcu, [0x81]);
        case Kiss.cmdFrequency:
          frequency = (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3];
          _cmd(Kiss.cmdFrequency, d);
        case Kiss.cmdBandwidth:
          bandwidth = (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3];
          _cmd(Kiss.cmdBandwidth,
              refuseBandwidth ? [0, 3, 0xD0, 0x90] : d);
        case Kiss.cmdTxPower:
          txPower = d[0];
          _cmd(Kiss.cmdTxPower, d);
        case Kiss.cmdSf:
          sf = d[0];
          _cmd(Kiss.cmdSf, [refuseSf ? 7 : d[0]]);
        case Kiss.cmdCr:
          cr = d[0];
          _cmd(Kiss.cmdCr, d);
        case Kiss.cmdRadioState:
          radioOn = d[0] == Kiss.radioStateOn;
          _cmd(Kiss.cmdRadioState, [radioOn ? 1 : 0]);
        case 0x41:
          framebufferOff = d.isNotEmpty && d[0] == 0;
        case Kiss.cmdLeave:
          leaveReceived = true;
        case Kiss.cmdData:
          transmitted.add(d);
          air?._tx(this, d);
          if (flowControl && autoReady) sendReady();
      }
    }
  }
}

class _EmuLink implements RNodeLink {
  _EmuLink(this.emu);
  final EmulatedRNode emu;
  final _rx = StreamController<Uint8List>();
  final _closed0 = Completer<void>();
  bool _closed = false;

  @override
  String get description => 'Emulated RNode';
  @override
  Stream<Uint8List> get received => _rx.stream;
  @override
  Future<void> get closed => _closed0.future;

  @override
  Future<void> write(Uint8List bytes) async {
    if (_closed) throw StateError('link closed');
    emu._hostWrote(bytes);
  }

  void _drop() {
    if (_closed) return;
    _closed = true;
    if (!_closed0.isCompleted) _closed0.complete();
    _rx.close();
  }

  @override
  Future<void> close() async => _drop();
}
