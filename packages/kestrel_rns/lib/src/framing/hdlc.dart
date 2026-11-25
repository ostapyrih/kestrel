import 'dart:typed_data';

/// HDLC-style framing used by Reticulum's TCP interfaces
/// (RNS/Interfaces/TCPInterface.py:44-53, read loop :403-430).
abstract final class Hdlc {
  static const int flag = 0x7E;
  static const int esc = 0x7D;
  static const int escMask = 0x20;

  /// Reticulum.HEADER_MINSIZE: frames of this size or smaller are dropped
  /// (TCPInterface.check_frame_len, :351).
  static const int headerMinSize = 19;

  /// TCPInterface.HW_MTU.
  static const int defaultHwMtu = 262144;

  /// Escapes `0x7D` first, then `0x7E` (order matters, TCPInterface.py:51-52).
  static Uint8List escape(List<int> data) {
    final out = BytesBuilder(copy: false);
    for (final b in data) {
      if (b == esc) {
        out
          ..addByte(esc)
          ..addByte(esc ^ escMask);
      } else if (b == flag) {
        out
          ..addByte(esc)
          ..addByte(flag ^ escMask);
      } else {
        out.addByte(b);
      }
    }
    return out.toBytes();
  }

  /// Reverse of [escape], implemented like the reference: first replace
  /// `7D 5E` with `7E`, then `7D 5D` with `7D` (TCPInterface.py:412-413).
  static Uint8List unescape(List<int> data) {
    final step1 = _replace(data, esc, flag ^ escMask, flag);
    return _replace(step1, esc, esc ^ escMask, esc);
  }

  /// Non-overlapping left-to-right replace of `[a, b]` by `[c]`, like
  /// Python's `bytes.replace`.
  static Uint8List _replace(List<int> data, int a, int b, int c) {
    final out = BytesBuilder(copy: false);
    var i = 0;
    while (i < data.length) {
      if (i + 1 < data.length && data[i] == a && data[i + 1] == b) {
        out.addByte(c);
        i += 2;
      } else {
        out.addByte(data[i]);
        i++;
      }
    }
    return out.toBytes();
  }

  /// `FLAG || escape(data) || FLAG`.
  static Uint8List frame(List<int> data) {
    final out = BytesBuilder(copy: false)
      ..addByte(flag)
      ..add(escape(data))
      ..addByte(flag);
    return out.toBytes();
  }
}

/// Streaming HDLC deframer mirroring the TCPInterface read loop, including
/// its quirks: the closing flag of a frame is kept as the opening flag of the
/// next, empty frames and frames of `<= 19` bytes are dropped, and an
/// unterminated buffer larger than `2 * hwMtu` is discarded.
class HdlcDecoder {
  HdlcDecoder({this.hwMtu = Hdlc.defaultHwMtu, this.ifacSize = 0});

  final int hwMtu;
  final int ifacSize;
  Uint8List _buf = Uint8List(0);

  /// Feeds received bytes; returns the complete valid frames.
  List<Uint8List> feed(List<int> chunk) {
    final frames = <Uint8List>[];
    _buf = Uint8List.fromList([..._buf, ...chunk]);
    while (true) {
      final start = _buf.indexOf(Hdlc.flag);
      if (start == -1) {
        _buf = Uint8List(0);
        break;
      }
      final end = _buf.indexOf(Hdlc.flag, start + 1);
      if (end == -1) {
        if (_buf.length > hwMtu * 2) _buf = Uint8List(0);
        break;
      }
      final frame = Hdlc.unescape(Uint8List.sublistView(_buf, start + 1, end));
      if (frame.isNotEmpty &&
          frame.length > Hdlc.headerMinSize &&
          frame.length <= hwMtu + ifacSize) {
        frames.add(frame);
      }
      _buf = Uint8List.fromList(Uint8List.sublistView(_buf, end));
    }
    return frames;
  }
}
