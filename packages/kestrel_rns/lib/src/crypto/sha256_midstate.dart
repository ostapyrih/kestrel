import 'dart:typed_data';

/// SHA-256 with a reusable mid-state, used by the stamp search.
///
/// A stamp is `SHA256(workblock || stamp)` where the workblock is hundreds of
/// kilobytes and the stamp a few dozen bytes. When the workblock length is a
/// multiple of 64 (always true for LXMF's `256 * rounds` workblocks) the
/// workblock can be compressed once and every candidate stamp costs a single
/// compression of its final block instead of re-hashing the whole workblock.
class Sha256Midstate {
  Sha256Midstate._(this._state, this._prefixLength);

  /// Compresses [prefix] (length must be a multiple of 64).
  factory Sha256Midstate(List<int> prefix) {
    if (prefix.length % 64 != 0) {
      throw ArgumentError('prefix length must be a multiple of 64');
    }
    final h = Uint32List.fromList(_iv);
    final w = Uint32List(64);
    final data = prefix is Uint8List ? prefix : Uint8List.fromList(prefix);
    for (var off = 0; off < data.length; off += 64) {
      _compress(h, data, off, w);
    }
    return Sha256Midstate._(h, prefix.length);
  }

  final Uint32List _state;
  final int _prefixLength;
  final Uint32List _h = Uint32List(8);
  final Uint32List _w = Uint32List(64);
  final Uint8List _block = Uint8List(64);

  /// Largest tail that still fits the single final block.
  static const int maxTail = 55;

  /// `SHA256(prefix || tail)` as 8 big-endian words in [out] (length 8).
  /// [tail] must be at most [maxTail] bytes.
  void finish(Uint8List tail, Uint32List out) {
    assert(tail.length <= maxTail);
    final b = _block;
    b.fillRange(0, 64, 0);
    b.setRange(0, tail.length, tail);
    b[tail.length] = 0x80;
    final bits = (_prefixLength + tail.length) * 8;
    // 64-bit big-endian length; the high word is 0 for anything we hash.
    final hi = (bits >> 32) & 0xFFFFFFFF;
    final lo = bits & 0xFFFFFFFF;
    b[56] = (hi >> 24) & 0xFF;
    b[57] = (hi >> 16) & 0xFF;
    b[58] = (hi >> 8) & 0xFF;
    b[59] = hi & 0xFF;
    b[60] = (lo >> 24) & 0xFF;
    b[61] = (lo >> 16) & 0xFF;
    b[62] = (lo >> 8) & 0xFF;
    b[63] = lo & 0xFF;
    _h.setRange(0, 8, _state);
    _compress(_h, b, 0, _w);
    out.setRange(0, 8, _h);
  }

  static const List<int> _iv = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];

  static final Uint32List _k = Uint32List.fromList(const [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ]);

  static int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

  static void _compress(Uint32List h, Uint8List d, int off, Uint32List w) {
    for (var i = 0; i < 16; i++) {
      final j = off + i * 4;
      w[i] = (d[j] << 24) | (d[j + 1] << 16) | (d[j + 2] << 8) | d[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final a = w[i - 15];
      final b = w[i - 2];
      final s0 = _rotr(a, 7) ^ _rotr(a, 18) ^ (a >> 3);
      final s1 = _rotr(b, 17) ^ _rotr(b, 19) ^ (b >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    var a = h[0], b = h[1], c = h[2], dd = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final t1 = (hh + s1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xFFFFFFFF;
      hh = g;
      g = f;
      f = e;
      e = (dd + t1) & 0xFFFFFFFF;
      dd = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    h[0] = (h[0] + a) & 0xFFFFFFFF;
    h[1] = (h[1] + b) & 0xFFFFFFFF;
    h[2] = (h[2] + c) & 0xFFFFFFFF;
    h[3] = (h[3] + dd) & 0xFFFFFFFF;
    h[4] = (h[4] + e) & 0xFFFFFFFF;
    h[5] = (h[5] + f) & 0xFFFFFFFF;
    h[6] = (h[6] + g) & 0xFFFFFFFF;
    h[7] = (h[7] + hh) & 0xFFFFFFFF;
  }
}
