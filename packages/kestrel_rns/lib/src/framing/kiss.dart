import 'dart:typed_data';

/// A decoded KISS frame: a command byte and its unescaped payload.
class KissFrame {
  const KissFrame(this.command, this.data);
  final int command;
  final Uint8List data;
}

/// KISS framing as used by RNode (RNS/Interfaces/RNodeInterface.py:40-105,
/// read loop :746) and the TCP KISS mode.
abstract final class Kiss {
  static const int fend = 0xC0;
  static const int fesc = 0xDB;
  static const int tfend = 0xDC;
  static const int tfesc = 0xDD;

  static const int cmdUnknown = 0xFE;
  static const int cmdData = 0x00;
  static const int cmdFrequency = 0x01;
  static const int cmdBandwidth = 0x02;
  static const int cmdTxPower = 0x03;
  static const int cmdSf = 0x04;
  static const int cmdCr = 0x05;
  static const int cmdRadioState = 0x06;
  static const int cmdRadioLock = 0x07;
  static const int cmdDetect = 0x08;
  static const int cmdFwVersion = 0x50;

  /// RNodeInterface.HW_MTU (:195).
  static const int rnodeHwMtu = 508;

  /// Escapes `0xDB` first, then `0xC0` (RNodeInterface.py:102-104).
  static Uint8List escape(List<int> data) {
    final out = BytesBuilder(copy: false);
    for (final b in data) {
      if (b == fesc) {
        out
          ..addByte(fesc)
          ..addByte(tfesc);
      } else if (b == fend) {
        out
          ..addByte(fesc)
          ..addByte(tfend);
      } else {
        out.addByte(b);
      }
    }
    return out.toBytes();
  }

  /// `FEND || command || escape(data) || FEND` (data frames use command 0).
  static Uint8List frame(List<int> data, {int command = cmdData}) {
    final out = BytesBuilder(copy: false)
      ..addByte(fend)
      ..addByte(command)
      ..add(escape(data))
      ..addByte(fend);
    return out.toBytes();
  }
}

/// Streaming KISS deframer, a byte-for-byte port of the RNodeInterface read
/// loop state machine, generalised to report every command (the reference
/// parses fixed-length payloads for non-data commands; framing is identical).
///
/// Quirks kept from the reference: the escape flag is not reset at FEND,
/// payload bytes beyond [hwMtu] are silently dropped, and a FEND received
/// before a command byte restarts the frame.
class KissDecoder {
  KissDecoder({this.hwMtu = Kiss.rnodeHwMtu});

  final int hwMtu;
  bool _inFrame = false;
  bool _escape = false;
  int _command = Kiss.cmdUnknown;
  final BytesBuilder _buf = BytesBuilder();

  /// Feeds received bytes; returns completed frames.
  List<KissFrame> feed(List<int> chunk) {
    final frames = <KissFrame>[];
    for (var byte in chunk) {
      if (_inFrame && byte == Kiss.fend && _command != Kiss.cmdUnknown) {
        _inFrame = false;
        frames.add(KissFrame(_command, _buf.takeBytes()));
      } else if (byte == Kiss.fend) {
        _inFrame = true;
        _command = Kiss.cmdUnknown;
        _buf.clear();
      } else if (_inFrame && _buf.length < hwMtu) {
        if (_buf.isEmpty && _command == Kiss.cmdUnknown) {
          _command = byte;
        } else if (byte == Kiss.fesc) {
          _escape = true;
        } else {
          if (_escape) {
            if (byte == Kiss.tfend) byte = Kiss.fend;
            if (byte == Kiss.tfesc) byte = Kiss.fesc;
            _escape = false;
          }
          _buf.addByte(byte);
        }
      }
    }
    return frames;
  }
}
