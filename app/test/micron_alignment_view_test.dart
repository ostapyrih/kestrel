import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/nomadnet/micron/micron_layout.dart';
import 'package:kestrel/nomadnet/micron/micron_parser.dart';
import 'package:kestrel/nomadnet/micron/micron_view.dart';
import 'package:material_ui/material_ui.dart';

/// Cell runs (text lengths in code units, in order) of every reference row
/// of a colour-block map, as NomadNet's MicronParser lays it out.
List<List<String>> _referenceRows() {
  final rows = jsonDecode(
    File('test/fixtures/micron/alert_map.ref.json').readAsStringSync(),
  ) as List;
  return [
    for (final r in rows)
      [
        for (final p in (r as List))
          if ((p['text'] as String).isNotEmpty) p['text'] as String,
      ],
  ];
}

Future<MicronViewState> _pump(
  WidgetTester tester,
  Size size,
  double dpr,
) async {
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey<MicronViewState>();
  final doc = parseMicron(
    File('test/fixtures/micron/alert_map.mu').readAsStringSync(),
  );
  await tester.pumpWidget(
    MaterialApp(
      // Material 3 text themes carry letter spacing: the page must not
      // inherit it.
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: MicronView(key: key, document: doc, onLink: (_, _) {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key.currentState!;
}

void main() {
  setUpAll(() async {
    final loader = FontLoader(micronFontFamily);
    for (final f in ['Regular', 'Bold']) {
      final bytes = File('assets/fonts/JetBrainsMono-$f.ttf').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  });

  for (final (name, size, dpr) in [
    ('phone', const Size(390, 844), 3.0),
    ('desktop', const Size(1200, 800), 1.0),
  ]) {
    testWidgets('$name: every cell of a colour map sits on the column grid', (
      tester,
    ) async {
      final st = await _pump(tester, size, dpr);
      final cw = st.effectiveFontSize * micronCharEm;
      final paragraphs = tester
          .renderObjectList<RenderParagraph>(find.byType(RichText))
          .toList();
      var checkedRows = 0;
      for (final row in _referenceRows()) {
        // map rows: several coloured cells
        if (row.length < 2 || row.join().length < 20) continue;
        final text = row.join();
        final p = paragraphs.where((p) => p.text.toPlainText() == text);
        expect(p, isNotEmpty, reason: 'row rendered as one paragraph: $text');
        final para = p.first;
        var col = 0;
        for (final cell in row) {
          final n = cell.length;
          final boxes = para.getBoxesForSelection(
            TextSelection(baseOffset: col, extentOffset: col + n),
          );
          expect(boxes, isNotEmpty);
          expect(
            boxes.first.left,
            closeTo(col * cw, 0.05),
            reason: 'cell at column $col in "$text"',
          );
          expect(
            boxes.last.right,
            closeTo((col + n) * cw, 0.05),
            reason: 'cell end at column ${col + n} in "$text"',
          );
          col += n;
        }
        expect(
          para.getMaxIntrinsicWidth(double.infinity),
          closeTo(col * cw, 0.05),
          reason: 'row width: $text',
        );
        checkedRows++;
      }
      expect(checkedRows, greaterThanOrEqualTo(6));
    });
  }

  testWidgets('page text style adds no tracking or ligatures', (tester) async {
    await _pump(tester, const Size(390, 844), 3);
    final p = tester
        .renderObjectList<RenderParagraph>(find.byType(RichText))
        .firstWhere((p) => p.text.toPlainText().contains('Sea of Azov'));
    final style = p.text.style!;
    expect(style.letterSpacing, 0);
    expect(style.wordSpacing, 0);
    expect(style.fontFeatures, contains(const FontFeature.disable('calt')));
  });
}
