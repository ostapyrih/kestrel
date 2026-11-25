import 'dart:convert';
import 'dart:typed_data';

/// Error while encoding or decoding MessagePack.
class MsgPackException implements Exception {
  MsgPackException(this.message);
  final String message;
  @override
  String toString() => 'MsgPackException: $message';
}

/// Minimal MessagePack codec matching the behaviour of `umsgpack`
/// (RNS/vendor/umsgpack.py) as used by RNS and LXMF:
///
/// * Dart `String` <-> msgpack `str`; `Uint8List` <-> msgpack `bin`
///   (never merged, unlike "compatibility" mode).
/// * Dart `int` <-> smallest msgpack integer encoding (umsgpack.py:283);
///   `double` <-> always float64 (`0xCB`), including integral values, so
///   `1700000000.0` stays a float.
/// * `List` <-> array, `Map` <-> map (insertion order preserved), `null`,
///   `bool`. `BigInt` is accepted for values in `[2^63, 2^64)`.
///
/// Decoding accepts every non-canonical width Python accepts (float32,
/// oversized ints/str/bin/array/map headers), rejects the reserved `0xC1`
/// code, invalid UTF-8 and duplicate map keys, and ignores trailing bytes
/// (like `umsgpack.unpackb`, which does not check for them).
/// ext types are not supported (LXMF/RNS do not use them).
Uint8List packb(Object? value) {
  final out = BytesBuilder(copy: false);
  _pack(value, out);
  return out.toBytes();
}

/// Decodes the first MessagePack object in [bytes].
Object? unpackb(List<int> bytes) {
  final r = _Reader(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  return r.read();
}

void _pack(Object? o, BytesBuilder out) {
  if (o == null) {
    out.addByte(0xC0);
  } else if (o is bool) {
    out.addByte(o ? 0xC3 : 0xC2);
  } else if (o is int) {
    _packInt(o, out);
  } else if (o is BigInt) {
    if (o >= BigInt.two.pow(63) && o < BigInt.two.pow(64)) {
      out.addByte(0xCF);
      final b = ByteData(8)
        ..setUint32(0, (o >> 32).toInt())
        ..setUint32(4, (o & BigInt.from(0xFFFFFFFF)).toInt());
      out.add(b.buffer.asUint8List());
    } else if (o.isValidInt) {
      _packInt(o.toInt(), out);
    } else {
      throw MsgPackException('huge integer');
    }
  } else if (o is double) {
    out.addByte(0xCB);
    out.add((ByteData(8)..setFloat64(0, o)).buffer.asUint8List());
  } else if (o is String) {
    final b = utf8.encode(o);
    final n = b.length;
    if (n < 32) {
      out.addByte(0xA0 | n);
    } else if (n < 0x100) {
      out
        ..addByte(0xD9)
        ..addByte(n);
    } else if (n < 0x10000) {
      out
        ..addByte(0xDA)
        ..add(_be(n, 2));
    } else {
      out
        ..addByte(0xDB)
        ..add(_be(n, 4));
    }
    out.add(b);
  } else if (o is Uint8List) {
    final n = o.length;
    if (n < 0x100) {
      out
        ..addByte(0xC4)
        ..addByte(n);
    } else if (n < 0x10000) {
      out
        ..addByte(0xC5)
        ..add(_be(n, 2));
    } else {
      out
        ..addByte(0xC6)
        ..add(_be(n, 4));
    }
    out.add(o);
  } else if (o is List<Object?>) {
    // (Uint8List handled above)
    final n = o.length;
    if (n < 16) {
      out.addByte(0x90 | n);
    } else if (n < 0x10000) {
      out
        ..addByte(0xDC)
        ..add(_be(n, 2));
    } else {
      out
        ..addByte(0xDD)
        ..add(_be(n, 4));
    }
    for (final e in o) {
      _pack(e, out);
    }
  } else if (o is Map<Object?, Object?>) {
    final n = o.length;
    if (n < 16) {
      out.addByte(0x80 | n);
    } else if (n < 0x10000) {
      out
        ..addByte(0xDE)
        ..add(_be(n, 2));
    } else {
      out
        ..addByte(0xDF)
        ..add(_be(n, 4));
    }
    o.forEach((k, v) {
      _pack(k, out);
      _pack(v, out);
    });
  } else {
    throw MsgPackException('unsupported type: ${o.runtimeType}');
  }
}

Uint8List _be(int v, int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[n - 1 - i] = (v >> (8 * i)) & 0xFF;
  }
  return b;
}

void _packInt(int v, BytesBuilder out) {
  if (v < 0) {
    if (v >= -32) {
      out.addByte(v & 0xFF);
    } else if (v >= -0x80) {
      out
        ..addByte(0xD0)
        ..addByte(v & 0xFF);
    } else if (v >= -0x8000) {
      out
        ..addByte(0xD1)
        ..add(_be(v & 0xFFFF, 2));
    } else if (v >= -0x80000000) {
      out
        ..addByte(0xD2)
        ..add(_be(v & 0xFFFFFFFF, 4));
    } else {
      out
        ..addByte(0xD3)
        ..add((ByteData(8)..setInt64(0, v)).buffer.asUint8List());
    }
  } else if (v < 128) {
    out.addByte(v);
  } else if (v < 0x100) {
    out
      ..addByte(0xCC)
      ..addByte(v);
  } else if (v < 0x10000) {
    out
      ..addByte(0xCD)
      ..add(_be(v, 2));
  } else if (v < 0x100000000) {
    out
      ..addByte(0xCE)
      ..add(_be(v, 4));
  } else {
    out
      ..addByte(0xCF)
      ..add((ByteData(8)..setInt64(0, v)).buffer.asUint8List());
  }
}

class _Reader {
  _Reader(this.b) : _bd = ByteData.sublistView(b);
  final Uint8List b;
  final ByteData _bd;
  int p = 0;

  int _need(int n) {
    if (p + n > b.length) throw MsgPackException('insufficient data');
    final s = p;
    p += n;
    return s;
  }

  int _u(int n) {
    final s = _need(n);
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 8) | b[s + i];
    }
    return v;
  }

  Object? read() {
    final code = b.length > p ? b[p++] : throw MsgPackException('empty');
    if (code <= 0x7F) return code;
    if (code >= 0xE0) return code - 256;
    if (code >= 0xA0 && code <= 0xBF) return _str(code & 0x1F);
    if (code >= 0x90 && code <= 0x9F) return _array(code & 0x0F);
    if (code >= 0x80 && code <= 0x8F) return _map(code & 0x0F);
    switch (code) {
      case 0xC0:
        return null;
      case 0xC2:
        return false;
      case 0xC3:
        return true;
      case 0xC4:
        return _bin(_u(1));
      case 0xC5:
        return _bin(_u(2));
      case 0xC6:
        return _bin(_u(4));
      case 0xCA:
        return _bd.getFloat32(_need(4));
      case 0xCB:
        return _bd.getFloat64(_need(8));
      case 0xCC:
        return _u(1);
      case 0xCD:
        return _u(2);
      case 0xCE:
        return _u(4);
      case 0xCF:
        final s = _need(8);
        final hi = _bd.getUint32(s);
        final lo = _bd.getUint32(s + 4);
        if (hi < 0x80000000) return (hi << 32) | lo;
        return (BigInt.from(hi) << 32) | BigInt.from(lo);
      case 0xD0:
        return _bd.getInt8(_need(1));
      case 0xD1:
        return _bd.getInt16(_need(2));
      case 0xD2:
        return _bd.getInt32(_need(4));
      case 0xD3:
        return _bd.getInt64(_need(8));
      case 0xD9:
        return _str(_u(1));
      case 0xDA:
        return _str(_u(2));
      case 0xDB:
        return _str(_u(4));
      case 0xDC:
        return _array(_u(2));
      case 0xDD:
        return _array(_u(4));
      case 0xDE:
        return _map(_u(2));
      case 0xDF:
        return _map(_u(4));
      case 0xC1:
        throw MsgPackException('encountered reserved code: 0xc1');
      default:
        throw MsgPackException('unsupported code 0x${code.toRadixString(16)}');
    }
  }

  String _str(int n) {
    final s = _need(n);
    try {
      return utf8.decode(Uint8List.sublistView(b, s, s + n));
    } on FormatException {
      throw MsgPackException('unpacked string is invalid utf-8');
    }
  }

  Uint8List _bin(int n) {
    final s = _need(n);
    return Uint8List.fromList(Uint8List.sublistView(b, s, s + n));
  }

  List<Object?> _array(int n) {
    if (n > b.length - p) throw MsgPackException('insufficient data');
    final l = <Object?>[];
    for (var i = 0; i < n; i++) {
      l.add(read());
    }
    return l;
  }

  Map<Object?, Object?> _map(int n) {
    if (n > (b.length - p) ~/ 2) throw MsgPackException('insufficient data');
    final m = <Object?, Object?>{};
    for (var i = 0; i < n; i++) {
      final k = read();
      if ((k is List<Object?> && k is! Uint8List) ||
          k is Map<Object?, Object?>) {
        throw MsgPackException('encountered unhashable key');
      }
      if (m.containsKey(k)) {
        throw MsgPackException('encountered duplicate key: $k');
      }
      m[k] = read();
    }
    return m;
  }
}
