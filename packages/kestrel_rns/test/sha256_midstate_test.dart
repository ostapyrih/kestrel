import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:kestrel_rns/src/crypto/sha256_midstate.dart';
import 'package:test/test.dart';

void main() {
  test('midstate finish equals sha256(prefix || tail)', () {
    for (final plen in [64, 128, 256 * 7]) {
      final prefix =
          Uint8List.fromList(List.generate(plen, (i) => (i * 31) & 0xFF));
      final mid = Sha256Midstate(prefix);
      for (final tlen in [0, 1, 14, 32, 55]) {
        final tail = Uint8List.fromList(List.generate(tlen, (i) => 200 - i));
        final out = Uint32List(8);
        mid.finish(tail, out);
        final bytes = <int>[
          for (final w in out) ...[
            (w >> 24) & 0xFF,
            (w >> 16) & 0xFF,
            (w >> 8) & 0xFF,
            w & 0xFF
          ],
        ];
        expect(bytes, sha256([...prefix, ...tail]), reason: '$plen/$tlen');
      }
    }
  });

  test('fast stamp search yields a valid stamp of the requested value', () {
    final wb = LxmStamper.workblock(List.filled(32, 7), expandRounds: 40);
    final s = Stamps.generate(wb, 12, size: 32)!;
    expect(Stamps.isValid(s, 12, wb), isTrue);
    expect(Stamps.value(wb, s), greaterThanOrEqualTo(12));
  });
}
