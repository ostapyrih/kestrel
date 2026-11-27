import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/nomadnet/micron/micron_layout.dart';
import 'package:kestrel/nomadnet/micron/micron_parser.dart';

/// Classification of the first block of [markup].
MicronLineInfo info(String markup, {int? pageBg}) {
  final doc = parseMicron(markup);
  final b = doc.blocks.firstWhere((b) => b.kind != MicronBlockKind.blank);
  return classifyMicronBlock(b, pageBg: pageBg ?? doc.background);
}

void main() {
  group('classification: structural (never wrapped)', () {
    test('figlet banner lines', () {
      for (final l in const [
        r' _  __          _            _ ',
        r'| |/ /___  ___ | |_ _ __ ___| |',
        r"| ' // _ \/ __|| __| '__/ _ \ |",
        r'| . \  __/\__ \| |_| | |  __/ |',
        r'|_|\_\___||___/ \__|_|  \___|_|',
      ]) {
        expect(info(l).structural, isTrue, reason: l);
      }
    });

    test('rule made of equals signs', () {
      expect(info('=' * 80).structural, isTrue);
      expect(info('+${'=' * 40}+').structural, isTrue);
    });

    test('colour-block map row with labels', () {
      final i = info('`B00a ВОЛ `B0a0 РІВ `Ba00 ХАР`b');
      expect(i.structural, isTrue);
      expect(i.solid, isTrue);
    });

    test('colour-block row of spaces only', () {
      expect(info('`Bf00      `B0f0      `b').structural, isTrue);
    });

    test('marker row with ^', () {
      expect(info('    ^        ^    ^').structural, isTrue);
    });

    test('literal block rows (tables)', () {
      final doc = parseMicron('`=\n| Name  | Value |\n| a     | 1     |\n`=');
      final rows = doc.blocks.where((b) => b.kind == MicronBlockKind.text);
      expect(rows, isNotEmpty);
      for (final b in rows) {
        expect(classifyMicronBlock(b).structural, isTrue);
      }
    });

    test('box drawing table row is solid', () {
      final i = info('│ Імʼя   │ Значення │');
      expect(i.structural, isTrue);
      expect(i.solid, isTrue);
    });

    test('aligned key/value columns', () {
      final i = info('Name:        Kestrel node');
      expect(i.structural, isTrue);
      expect(i.solid, isFalse);
    });

    test('page background colour alone is not a line background', () {
      final doc = parseMicron('#!bg=222\nHello there, ordinary prose here.');
      final b = doc.blocks.firstWhere((b) => b.plainText.startsWith('Hello'));
      expect(
        classifyMicronBlock(b, pageBg: doc.background).structural,
        isFalse,
      );
    });
  });

  group('classification: prose (wraps)', () {
    test('two spaces after a sentence end are still prose', () {
      expect(
        info('First sentence here.  Second one follows!  And a third?  Yes.')
            .structural,
        isFalse,
      );
      expect(info('Key:  value').structural, isFalse);
      expect(info('word  word').structural, isTrue);
    });

    test('Cyrillic prose', () {
      final i = info(
        'Ласкаво просимо на вузол! Тут можна читати сторінки, '
        'залишати повідомлення та знаходити інших користувачів мережі.',
      );
      expect(i.structural, isFalse);
    });

    test('long English prose line', () {
      expect(
        info(
          'This is a very long ordinary paragraph of English text that goes on '
          'and on, with commas, (parentheses), a dash - and even a [bracket] '
          'or two, but is still simply prose that should wrap.',
        ).structural,
        isFalse,
      );
    });

    test('bullet and indented prose', () {
      expect(info('* one item of a list').structural, isFalse);
      expect(
        info('  Indented paragraph start, then ordinary words.').structural,
        isFalse,
      );
    });

    test('a link in prose', () {
      expect(
        info('See `[the guide`abc:/page/guide.mu] for more').structural,
        isFalse,
      );
    });

    test('dividers and headings are not text rows', () {
      final doc = parseMicron('-\n> Title');
      expect(doc.blocks.first.kind, MicronBlockKind.divider);
      for (final b in doc.blocks) {
        expect(classifyMicronBlock(b).structural, isFalse);
      }
    });
  });

  group('columns', () {
    test('wide characters count two columns', () {
      expect(displayColumns('abc'), 3);
      expect(displayColumns('ВОЛ РІВ'), 7);
      expect(displayColumns('日本'), 4);
      expect(displayColumns('e\u0301'), 1);
      expect(displayColumns('█' * 5), 5);
    });

    test('widest structural line ignores prose', () {
      final doc = parseMicron('${'x ' * 100}\n${'=' * 30}\n`B00a${' ' * 44}`b');
      expect(widestStructuralColumns(doc), 44);
    });
  });

  group('fitMicron', () {
    test('scales down to fit, never up', () {
      final f = fitMicron(
        viewport: 400,
        columns: 60,
        baseFont: 14,
        padding: 24,
      );
      expect(f.fontSize, 10); // 10.44 floored to a whole device pixel
      expect(f.scrolls, isFalse);
      final wide = fitMicron(
        viewport: 1200,
        columns: 60,
        baseFont: 14,
        padding: 24,
      );
      expect(wide.fontSize, 14);
      expect(wide.scrolls, isFalse);
    });

    test('scrolls only below the minimum size', () {
      final f = fitMicron(viewport: 366, columns: 200, baseFont: 14);
      expect(f.fontSize, micronMinFontSize);
      expect(f.scrolls, isTrue);
      expect(f.contentWidth, closeTo(200 * 0.6 * micronMinFontSize, 0.01));
    });

    test('snaps to device pixels and keeps fitting', () {
      final f = fitMicron(viewport: 390, columns: 53, baseFont: 14, dpr: 3);
      expect((f.fontSize * 3), closeTo((f.fontSize * 3).roundToDouble(), 1e-9));
      expect(53 * 0.6 * f.fontSize, lessThanOrEqualTo(390));
      expect(f.scrolls, isFalse);
    });

    test('zoom multiplies the fitted size', () {
      final f = fitMicron(viewport: 366, columns: 60, baseFont: 14, zoom: 2);
      expect(f.fontSize, 20);
      expect(f.scrolls, isTrue);
    });

    test('no structural lines: base size', () {
      expect(fitMicron(viewport: 300, columns: 0, baseFont: 14).fontSize, 14);
    });
  });
}
