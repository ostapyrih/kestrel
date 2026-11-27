import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/main.dart';
import 'package:kestrel/node/node_service.dart';
import 'package:kestrel/screens/chat_screen.dart';
import 'package:kestrel/storage/chat_target.dart';
import 'package:material_ui/material_ui.dart';

import 'support/fixtures.dart';

void main() {
  final input = find.byKey(const ValueKey('composer-input'));

  Future<FakeNode> open(WidgetTester tester, {Widget? screen}) async {
    final node = FakeNode();
    const locale = Locale('uk');
    tester.platformDispatcher.localeTestValue = locale;
    tester.platformDispatcher.localesTestValue = [locale];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(840, 1720);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: fixtureOverrides(conn: NodeConnection.online, node: node),
        child: KestrelApp(home: screen ?? const ChatScreen(chatId: 1)),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(input);
    await tester.pump();
    return node;
  }

  bool focused(WidgetTester t) =>
      t.widget<TextField>(input).focusNode!.hasFocus;

  testWidgets('Enter sends and keeps focus', (tester) async {
    final node = await open(tester);
    await tester.enterText(input, 'hello');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(node.sent, [(1, 'hello')]);
    expect(tester.widget<TextField>(input).controller!.text, '');
    expect(focused(tester), isTrue);
  });

  testWidgets('numpad Enter sends', (tester) async {
    final node = await open(tester);
    await tester.enterText(input, 'hi');
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.pump();
    expect(node.sent, [(1, 'hi')]);
  });

  testWidgets('Shift+Enter is left to the field (newline) and does not send', (
    tester,
  ) async {
    final node = await open(tester);
    await tester.enterText(input, 'a');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(node.sent, isEmpty);
    // the newline comes from the platform text input (not emulated here)
    expect(tester.widget<TextField>(input).controller!.text, 'a');
    expect(focused(tester), isTrue);
  });

  testWidgets('Enter on empty or blank text does nothing', (tester) async {
    final node = await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.enterText(input, '  ');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(node.sent, isEmpty);
    expect(focused(tester), isTrue);
  });

  testWidgets('Enter during IME composition does not send', (tester) async {
    final node = await open(tester);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(node.sent, isEmpty);
    expect(tester.widget<TextField>(input).controller!.text, 'ni');
  });

  testWidgets('Ctrl+Enter sends', (tester) async {
    final node = await open(tester);
    await tester.enterText(input, 'yo');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(node.sent, [(1, 'yo')]);
    expect(focused(tester), isTrue);
  });

  testWidgets('Enter sends the first message of a draft chat', (tester) async {
    final node = await open(
      tester,
      screen: ChatScreen(
        draft: ChatTarget(chatId: null, identity: 'B', peer: 'cc' * 16),
      ),
    );
    await tester.enterText(input, 'first');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(node.draftSends, [('cc' * 16, 'first')]);
  });
}
