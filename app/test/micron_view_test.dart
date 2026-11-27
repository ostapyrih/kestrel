import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/nomadnet/micron/micron_parser.dart';
import 'package:kestrel/nomadnet/micron/micron_view.dart';

Future<List<(String, Map<String, String>?)>> pump(
  WidgetTester tester,
  String markup, {
  Brightness brightness = Brightness.light,
  Size size = const Size(420, 800),
}) async {
  final taps = <(String, Map<String, String>?)>[];
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: MicronView(
          document: parseMicron(markup, dark: brightness == Brightness.dark),
          onLink: (t, d) => taps.add((t, d)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return taps;
}

void main() {
  testWidgets('renders text, is selectable and monospace', (tester) async {
    await pump(tester, 'hello `!bold`! world');
    expect(find.byType(SelectionArea), findsOneWidget);
    final rich = tester.widget<Text>(find.byType(Text).first);
    final span = rich.textSpan! as TextSpan;
    expect(span.children!.length, 3);
    final style = (span.children![1] as TextSpan).style!;
    expect(style.fontWeight, FontWeight.bold);
    expect(style.fontFamily, 'JetBrainsMono');
  });

  testWidgets('tapping a link reports target and no data', (tester) async {
    final taps = await pump(tester, '`[Go`abc:/page/x.mu] now');
    final text = tester.widget<Text>(find.byType(Text).first);
    final link = (text.textSpan! as TextSpan).children!.first as TextSpan;
    (link.recognizer! as dynamic).onTap!();
    expect(taps.single.$1, 'abc:/page/x.mu');
    expect(taps.single.$2, isNull);
  });

  testWidgets('submit link sends field_* for named fields, var_* for k=v', (
    tester,
  ) async {
    final taps = await pump(
      tester,
      'Name: `<user`>\n`<!8|pw`>\n`[Send`:/p`user|mode=x]\n`[All`:/p`*]',
    );
    await tester.enterText(
      find.byKey(const ValueKey('micron-field-user-0-1')),
      'Оля',
    );
    await tester.enterText(
      find.byKey(const ValueKey('micron-field-pw-1-0')),
      's3',
    );
    Future<void> tapLink(String label) async {
      final texts = tester.widgetList<Text>(find.byType(Text));
      for (final t in texts) {
        final root = t.textSpan;
        if (root is! TextSpan) continue;
        for (final c in root.children ?? const <InlineSpan>[]) {
          if (c is TextSpan && c.text == label) {
            (c.recognizer! as dynamic).onTap!();
            return;
          }
        }
      }
      fail('link $label not found');
    }

    await tapLink('Send');
    expect(taps.last.$2, {'var_mode': 'x', 'field_user': 'Оля'});
    await tapLink('All');
    expect(taps.last.$2, {'field_user': 'Оля', 'field_pw': 's3'});
  });

  testWidgets('masked fields obscure text', (tester) async {
    await pump(tester, '`<!8|pw`>');
    final f = tester.widget<TextField>(find.byType(TextField));
    expect(f.obscureText, isTrue);
  });

  testWidgets('checkboxes join with commas; radios send the selected value', (
    tester,
  ) async {
    final taps = await pump(
      tester,
      '`<?|opt|a`A>\n`<?|opt|b|*`B>\n`<?|opt|c`C>\n'
      '`<^|size|s`S>\n`<^|size|l`L>\n`[Go`:/p`*]',
    );
    await tester.tap(find.text('A'));
    await tester.pump();
    await tester.tap(find.text('L'));
    await tester.pump();
    await tester.tap(find.text('S'));
    await tester.pump();
    final texts = tester.widgetList<Text>(find.byType(Text));
    for (final t in texts) {
      final root = t.textSpan;
      if (root is TextSpan) {
        for (final c in root.children ?? const <InlineSpan>[]) {
          if (c is TextSpan && c.text == 'Go') {
            (c.recognizer! as dynamic).onTap!();
          }
        }
      }
    }
    // A (tapped) and B (pre-checked), not C; radio: last tap wins (S)
    expect(taps.single.$2, {'field_opt': 'a,b', 'field_size': 's'});
  });

  testWidgets('radio buttons in a group are exclusive', (tester) async {
    await pump(tester, '`<^|g|1`One>\n`<^|g|2|*`Two>');
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    await tester.tap(find.text('One'));
    await tester.pump();
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
  });

  testWidgets('collapsible headings hide deeper content', (tester) async {
    await pump(tester, '`+>>Section\ninner text\n<outer');
    expect(find.textContaining('inner text'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('micron-fold-0')));
    await tester.pump();
    expect(find.textContaining('inner text'), findsNothing);
    expect(find.textContaining('outer'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('micron-fold-0')));
    await tester.pump();
    expect(find.textContaining('inner text'), findsOneWidget);
  });

  testWidgets('initially collapsed heading', (tester) async {
    await pump(tester, '`->>Closed\nhidden');
    expect(find.textContaining('hidden'), findsNothing);
  });

  testWidgets('light and dark themes give readable default colours', (
    tester,
  ) async {
    await pump(tester, 'plain', brightness: Brightness.dark);
    var span =
        tester.widget<Text>(find.byType(Text).first).textSpan! as TextSpan;
    final dark = (span.children!.first as TextSpan).style!.color!;
    await pump(tester, 'plain', brightness: Brightness.light);
    span = tester.widget<Text>(find.byType(Text).first).textSpan! as TextSpan;
    final light = (span.children!.first as TextSpan).style!.color!;
    expect(dark.computeLuminance(), greaterThan(light.computeLuminance()));
  });

  testWidgets('page colours: #!bg with no fg picks a contrasting text colour', (
    tester,
  ) async {
    await pump(tester, '#!bg=000\ntext', brightness: Brightness.light);
    final span =
        tester.widget<Text>(find.byType(Text).first).textSpan! as TextSpan;
    expect(
      (span.children!.first as TextSpan).style!.color!.computeLuminance(),
      greaterThan(0.5),
    );
  });

  testWidgets('dividers, headings and aligned text build without errors', (
    tester,
  ) async {
    await pump(tester, '>H1\n-\n`ccentre\n`rright\n-=\n>>>deep\ntext');
    expect(tester.takeException(), isNull);
    expect(find.text('H1'), findsOneWidget);
  });

  testWidgets('a long page scrolls lazily and a link target can be reached', (
    tester,
  ) async {
    final md = List.generate(500, (i) => 'line $i').join('\n');
    await pump(tester, md);
    expect(find.textContaining('line 499'), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, -100000));
    await tester.pump();
    expect(find.textContaining('line 499'), findsOneWidget);
  });

  testWidgets('anchor links scroll within the page and are not forwarded', (
    tester,
  ) async {
    final md =
        '`[Down`#end]\n${List.generate(300, (i) => 'l$i').join('\n')}\n`:end\nTHE END';
    final taps = await pump(tester, md);
    final span =
        tester.widget<Text>(find.byType(Text).first).textSpan! as TextSpan;
    (span.children!.first as TextSpan).recognizer! as dynamic;
    ((span.children!.first as TextSpan).recognizer! as dynamic).onTap!();
    await tester.pumpAndSettle();
    expect(taps, isEmpty);
    expect(find.text('THE END'), findsOneWidget);
  });
}
