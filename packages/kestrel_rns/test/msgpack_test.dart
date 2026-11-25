import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import 'support/vectors.dart';

void main() {
  final mv = loadVectors('msgpack.json');

  group('canonical vectors', () {
    for (final v in maps(mv['vectors'])) {
      test(v['name']! as String, () {
        final tree = fromTree(v['tree']);
        expect(hex(packb(tree)), v['hex'], reason: 'pack');
        final back = unpackb(unhex(v['hex'] as String?));
        expect(deepEquals(back, tree), isTrue, reason: 'unpack: $back');
      });
    }
  });

  group('decode-only (non-canonical encodings)', () {
    for (final v in maps(mv['decode_only'])) {
      test(v['name']! as String, () {
        final tree = fromTree(v['tree']);
        final back = unpackb(unhex(v['hex'] as String?));
        expect(deepEquals(back, tree), isTrue, reason: '$back');
        expect(hex(packb(back)), v['canonical_hex']);
      });
    }
  });

  group('invalid', () {
    for (final v in maps(mv['invalid'])) {
      test(v['name']! as String, () {
        expect(
          () => unpackb(unhex(v['hex'] as String?)),
          throwsA(isA<MsgPackException>()),
        );
      });
    }
  });

  test('bin and str never merge; int and float never merge', () {
    expect(hex(packb(Uint8List.fromList([0x61]))), 'c40161');
    expect(hex(packb('a')), 'a161');
    expect(hex(packb(1)), '01');
    expect(hex(packb(1.0)), 'cb3ff0000000000000');
    expect(unpackb(unhex('cb3ff0000000000000')), isA<double>());
    expect(unpackb(unhex('01')), isA<int>());
    expect(unpackb(unhex('c40161')), isA<Uint8List>());
  });

  test('unsupported types rejected', () {
    expect(() => packb(Object()), throwsA(isA<MsgPackException>()));
  });
}
