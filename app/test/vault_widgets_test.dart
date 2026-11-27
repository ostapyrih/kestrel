import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/bridge/vault_service.dart';
import 'package:kestrel/main.dart';
import 'package:kestrel/node/node_service.dart';
import 'package:kestrel/screens/chat_screen.dart';
import 'package:kestrel/screens/chats_screen.dart';
import 'package:kestrel/screens/settings_screen.dart';
import 'package:material_ui/material_ui.dart';

import 'support/fixtures.dart';

void main() {
  late FakeNode node;
  late FakeBridge bridge;

  Future<void> show(
    WidgetTester tester,
    Widget home, {
    String lang = 'uk',
    bool configured = true,
    bool withRemote = true,
    VaultStatus vault = const VaultStatus(state: VaultState.idle),
  }) async {
    final locale = Locale(lang);
    tester.platformDispatcher.localeTestValue = locale;
    tester.platformDispatcher.localesTestValue = [locale];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(840, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: fixtureOverrides(
          conn: NodeConnection.online,
          node: node,
          bridge: bridge,
          bridgeConfigured: configured,
          withRemote: withRemote,
          vaultStatus: vault,
        ),
        child: KestrelApp(home: home),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  setUp(() {
    node = FakeNode();
    bridge = FakeBridge();
  });

  group('chat list', () {
    testWidgets('remote history shows the "B · device" badge and a chip', (
      tester,
    ) async {
      await show(tester, const ChatsScreen());
      expect(find.text('Remote peer'), findsOneWidget);
      final badge = find.byKey(const ValueKey('badge-remote'));
      expect(badge, findsOneWidget);
      expect(
        find.descendant(of: badge, matching: find.text('B · iPhone')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('chip-R')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chip-R')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Remote peer'), findsOneWidget);
      expect(find.text('Alice'), findsNothing);
    });

    testWidgets('nothing vault-related while the bridge is off', (
      tester,
    ) async {
      await show(tester, const ChatsScreen(), configured: false);
      expect(find.byKey(const ValueKey('badge-remote')), findsNothing);
      expect(find.byKey(const ValueKey('chip-R')), findsNothing);
      expect(find.text('Remote peer'), findsNothing);
    });
  });

  group('read-only chat', () {
    testWidgets('banner, message line with the device, no composer', (
      tester,
    ) async {
      await show(tester, const ChatScreen(chatId: -1));
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('readonly-text'))).data,
        'Історія з iPhone · лише читання',
      );
      expect(find.byKey(const ValueKey('vault-reply')), findsOneWidget);
      expect(find.text('Відповісти з цього пристрою'), findsOneWidget);
      expect(find.byKey(const ValueKey('composer-input')), findsNothing);
      expect(find.byKey(const ValueKey('composer-send')), findsNothing);
      // the usual "sender · route · transport" line, with the remote device
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('meta--1'))).data,
        'B · iPhone · direct · TCP',
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('badge-remote')),
          matching: find.text('B · iPhone'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('English banner', (tester) async {
      await show(tester, const ChatScreen(chatId: -1), lang: 'en');
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('readonly-text'))).data,
        'History from iPhone · read only',
      );
      expect(find.text('Reply from this device'), findsOneWidget);
    });

    testWidgets('an own chat keeps its composer and has no banner', (
      tester,
    ) async {
      await show(tester, const ChatScreen(chatId: 1));
      expect(find.byKey(const ValueKey('readonly-banner')), findsNothing);
      expect(find.byKey(const ValueKey('composer-input')), findsOneWidget);
    });

    testWidgets('"Reply from this device" opens the chat with the same peer '
        'in this device (B) when there is no bridge identity choice', (
      tester,
    ) async {
      await show(tester, const ChatScreen(chatId: -1), configured: false);
      await tester.tap(find.byKey(const ValueKey('vault-reply')));
      await tester.pumpAndSettle();
      expect(node.opened, ['cc' * 16]);
    });

    testWidgets('with the bridge on the user picks B or A', (tester) async {
      await show(tester, const ChatScreen(chatId: -1));
      await tester.tap(find.byKey(const ValueKey('vault-reply')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reply-as-A')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reply-as-B')));
      await tester.pumpAndSettle();
      expect(node.opened, ['cc' * 16]);
    });
  });

  group('settings', () {
    testWidgets('sync status section', (tester) async {
      await show(
        tester,
        const SettingsScreen(),
        vault: VaultStatus(
          state: VaultState.idle,
          lastSync: DateTime(2026, 11, 25, 12, 30),
          usedBytes: 2048,
          quotaBytes: 64 * 1024 * 1024,
          remoteDevices: 2,
        ),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('vault-section')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Синхронізовано'), findsOneWidget);
      expect(find.textContaining('2.0 KiB з 64.0 MiB'), findsOneWidget);
      expect(find.textContaining('отриманою історією: 2'), findsOneWidget);
      expect(find.textContaining('12:30'), findsOneWidget);
    });

    testWidgets('waiting for a key from another device is explained', (
      tester,
    ) async {
      await show(
        tester,
        const SettingsScreen(),
        vault: const VaultStatus(state: VaultState.needsKey),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('vault-section')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Очікування ключа від іншого пристрою'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('vault-needs-key-help')),
        findsOneWidget,
      );
    });

    testWidgets('no vault section when the bridge is off', (tester) async {
      await show(tester, const SettingsScreen(), configured: false);
      expect(find.byKey(const ValueKey('vault-section')), findsNothing);
    });
  });
}
