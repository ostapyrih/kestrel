import 'dart:typed_data';

/// Lower-case hex of [b].
String toHex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

/// Parses a hex string.
Uint8List fromHex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

/// Current time as unix seconds with sub-second precision (Python
/// `time.time()`).
double unixNow() => DateTime.now().microsecondsSinceEpoch / 1e6;
