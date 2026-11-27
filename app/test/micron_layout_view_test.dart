import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/nomadnet/micron/micron_layout.dart';
import 'package:kestrel/nomadnet/micron/micron_parser.dart';
import 'package:kestrel/nomadnet/micron/micron_view.dart';
import 'package:material_ui/material_ui.dart';

// no backslashes or leading '#': both are Micron syntax
const _banner = [
  r' _  _  ___  ___ _____ ___ ___ _    _  _  ___  ___ _____ ___ ___ _ ',
  r'| |/ /| __|/ __|_   _| _ ( __| |  | |/ /| __|/ __|_   _| _ ( __| |',
  r'| . < | _| ( _ ( | | |   / _|| |__| . < | _| ( _ ( | | |   / _|| |',
];

/// A colour-map row: one two-column cell per colour, with optional labels.
String _mapRow(List<String> colours, [List<String>? labels]) => [
  for (var i = 0; i < colours.length; i++)
    '`B${colours[i]}${(labels?[i] ?? '').padRight(2).substring(0, 2)}',
].join();

final _prose =
    'Це звичайний абзац тексту, який має переноситися по словах на вузькому '
        'екрані, бо тут немає ні малюнків, ні вирівнювання. ' *
    2;

final _row1 = _mapRow(
  ['d00', 'd00', '0a0', '0a0', '00d', '00d'],
  ['', 'ВО', '', 'РІ', 'ХА', ''],
);

final _page = [
  ..._banner,
  '',
  _row1 * 5,
  _mapRow(['d00', 'd00', '0a0', '0a0', '00d', '00d']) * 5,
  _mapRow(['0a0', '0a0', 'd00', 'd00', '00d', '00d']) * 5,
  '`b',
  _prose,
].join('\n');

Future<GlobalKey<MicronViewState>> pumpPage(
  WidgetTester tester,
  String markup, {
  Size size = const Size(390, 844),
  double dpr = 3,
  double zoom = 1,
  bool wrapAll = false,
  ValueChanged<double>? onZoom,
}) async {
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey<MicronViewState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MicronView(
          key: key,
          document: parseMicron(markup),
          onLink: (_, _) {},
          zoom: zoom,
          wrapAll: wrapAll,
          onZoomChanged: onZoom,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key;
}

RenderParagraph para(WidgetTester tester, Finder f) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(of: f, matching: find.byType(RichText)).first,
    );

Finder textStarting(String s) => find.byWidgetPredicate(
  (w) => w is Text && (w.textSpan?.toPlainText() ?? w.data ?? '').startsWith(s),
);

/// Number of visual lines (distinct box tops of the whole text).
int lineCount(WidgetTester tester, Finder f) {
  final p = para(tester, f);
  final n = p.text.toPlainText().length;
  final tops = {
    for (final b in p.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: n),
    ))
      b.top.round(),
  };
  return tops.length;
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

  group('phone 390x844', () {
    testWidgets('banner and map rows are single lines, font scaled to fit', (
      tester,
    ) async {
      final key = await pumpPage(tester, _page);
      final st = key.currentState!;
      expect(st.effectiveFontSize, lessThan(14));
      expect(st.effectiveFontSize, greaterThanOrEqualTo(micronMinFontSize));
      expect(st.scrollsHorizontally, isFalse);
      for (final l in _banner) {
        final f = textStarting(l.substring(0, 12));
        expect(f, findsOneWidget, reason: l);
        expect(lineCount(tester, f), 1, reason: l);
        // fits the viewport minus the 12px side padding
        expect(tester.getSize(f).width, lessThanOrEqualTo(390 - 24 + 0.01));
      }
      final row = textStarting('  ВО');
      expect(row, findsOneWidget);
      expect(lineCount(tester, row), 1);
      expect(find.byKey(const ValueKey('micron-hscroll')), findsNothing);
    });

    testWidgets('rows of background colour touch (no vertical gaps)', (
      tester,
    ) async {
      final key = await pumpPage(tester, _page);
      final fs = key.currentState!.effectiveFontSize;
      final rows = find.byWidgetPredicate(
        (w) => w is Text && (w.textSpan?.toPlainText() ?? '').length == 60,
      );
      expect(rows, findsNWidgets(3));
      final rects = [
        for (final e in rows.evaluate())
          tester.getRect(find.byWidget(e.widget)),
      ];
      for (var i = 0; i + 1 < rects.length; i++) {
        expect(rects[i].height, closeTo(fs, 0.01), reason: 'line height 1.0');
        expect(rects[i + 1].top, closeTo(rects[i].bottom, 0.01));
      }
    });

    testWidgets('prose wraps at the same font size', (tester) async {
      final key = await pumpPage(tester, _page);
      final f = textStarting('Це звичайний абзац');
      expect(lineCount(tester, f), greaterThan(1));
      expect(tester.getSize(f).width, lessThanOrEqualTo(390 - 24 + 0.01));
      expect(
        para(tester, f).text.style!.fontSize,
        key.currentState!.effectiveFontSize,
      );
    });

    testWidgets('below the minimum size the page scrolls, never wraps', (
      tester,
    ) async {
      final wide = '${'%' * 120}\n$_prose';
      final key = await pumpPage(tester, wide);
      final st = key.currentState!;
      expect(st.effectiveFontSize, micronMinFontSize);
      expect(st.scrollsHorizontally, isTrue);
      expect(find.byKey(const ValueKey('micron-hscroll')), findsOneWidget);
      final art = textStarting('%' * 20);
      expect(lineCount(tester, art), 1);
      expect(tester.getSize(art).width, greaterThan(390));
      // prose is still limited to the viewport
      final p = textStarting('Це звичайний абзац');
      expect(tester.getSize(p).width, lessThanOrEqualTo(390 - 24 + 0.01));
      expect(lineCount(tester, p), greaterThan(1));
    });

    testWidgets('wrapAll wraps structural lines and does not scroll', (
      tester,
    ) async {
      final key = await pumpPage(tester, _page, wrapAll: true);
      final st = key.currentState!;
      expect(st.effectiveFontSize, 14);
      expect(st.scrollsHorizontally, isFalse);
      expect(lineCount(tester, textStarting(_banner[1].substring(0, 12))), 2);
    });

    testWidgets('zoom multiplies the fitted size', (tester) async {
      final fit = (await pumpPage(
        tester,
        _page,
      )).currentState!.effectiveFontSize;
      final key = await pumpPage(tester, _page, zoom: 1.5);
      expect(key.currentState!.effectiveFontSize, greaterThan(fit));
    });

    testWidgets('pinch changes the zoom, double tap resets to fit', (
      tester,
    ) async {
      final zooms = <double>[];
      final key = await pumpPage(tester, _page, onZoom: zooms.add);
      final fit = key.currentState!.effectiveFontSize;
      final c = tester.getCenter(find.byType(MicronView));
      final a = await tester.startGesture(c - const Offset(40, 0));
      final b = await tester.startGesture(c + const Offset(40, 0));
      await a.moveTo(c - const Offset(100, 0));
      await b.moveTo(c + const Offset(100, 0));
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(key.currentState!.effectiveFontSize, greaterThan(fit));
      expect(zooms, isNotEmpty);
      expect(zooms.last, greaterThan(1));

      await tester.tapAt(c);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(c);
      await tester.pumpAndSettle();
      expect(key.currentState!.effectiveFontSize, fit);
      expect(zooms.last, 1.0);
    });
  });

  group('desktop 1200x800', () {
    testWidgets('normal font size, no scaling, no scrolling', (tester) async {
      final key = await pumpPage(
        tester,
        _page,
        size: const Size(1200, 800),
        dpr: 1,
      );
      expect(key.currentState!.effectiveFontSize, 14);
      expect(key.currentState!.scrollsHorizontally, isFalse);
      expect(lineCount(tester, textStarting(_banner[1].substring(0, 12))), 1);
    });
  });
}
