import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/main.dart';
import 'package:kestrel/node/node_service.dart';
import 'package:kestrel/platform.dart';
import 'package:kestrel/screens/chat_screen.dart';
import 'package:kestrel/screens/chats_screen.dart';
import 'package:kestrel/screens/new_chat_screen.dart';
import 'package:kestrel/screens/settings_screen.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<void> show(
    WidgetTester tester,
    Widget home, {
    NodeConnection conn = NodeConnection.online,
    FakeNode? node,
    Repo? repo,
    Locale locale = const Locale('uk'),
    Size size = const Size(420, 860),
  }) async {
    tester.platformDispatcher.localeTestValue = locale;
    tester.platformDispatcher.localesTestValue = [locale];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: fixtureOverrides(conn: conn, node: node, repo: repo),
        child: KestrelApp(home: home),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  group('responsive layout', () {
    testWidgets('narrow: single pane, tap pushes the chat', (tester) async {
      await show(tester, const ChatsScreen());
      expect(find.text('Оберіть чат зі списку'), findsNothing);
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(ChatsScreen), findsNothing);
    });

    testWidgets('wide: list on the left, selected chat on the right', (
      tester,
    ) async {
      await show(tester, const ChatsScreen(), size: const Size(1200, 800));
      expect(find.text('Оберіть чат зі списку'), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
      await tester.tap(find.text('Alice'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Оберіть чат зі списку'), findsNothing);
      expect(find.byType(ChatScreen), findsOneWidget);
      // the list stays visible next to the open chat
      expect(find.byType(ChatsScreen), findsOneWidget);
      expect(find.text('Marichka'), findsOneWidget);
    });
  });

  group('chats list', () {
    testWidgets('shows chats with identity badges and the TCP indicator', (
      tester,
    ) async {
      await show(tester, const ChatsScreen());
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Marichka'), findsOneWidget);
      expect(find.text('TCP Online'), findsOneWidget);
      // one badge per chat row: B for Alice, A for Marichka
      expect(find.byKey(const ValueKey('badge-B')), findsOneWidget);
      expect(find.byKey(const ValueKey('badge-A')), findsOneWidget);
      expect(find.text('Привіт!'), findsOneWidget);
    });

    testWidgets('offline indicator', (tester) async {
      await show(tester, const ChatsScreen(), conn: NodeConnection.offline);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('TCP Online'), findsNothing);
    });

    testWidgets('account switcher: B, A (disabled, hint) and All', (
      tester,
    ) async {
      await show(tester, const ChatsScreen());
      expect(find.text('B (телефон)'), findsOneWidget);
      expect(find.text('A (міст)'), findsWidgets);
      expect(find.text('Усі'), findsOneWidget);
      final a = tester.widget<ChoiceChip>(find.byKey(const ValueKey('chip-A')));
      expect(a.onSelected, isNull); // disabled until the bridge exists
      expect(find.byTooltip('увімкніть міст'), findsOneWidget);
      expect(find.textContaining('увімкніть міст'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('chip-B')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Marichka'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('chip-all')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Marichka'), findsOneWidget);
    });

    testWidgets('English fallback for English devices', (tester) async {
      await show(tester, const ChatsScreen(), locale: const Locale('en'));
      expect(find.text('New chat'), findsOneWidget);
      expect(find.text('B (phone)'), findsOneWidget);
      await show(tester, const ChatsScreen(), locale: const Locale('de'));
      expect(find.text('Новий чат'), findsOneWidget); // Ukrainian default
    });
  });

  group('chat detail', () {
    testWidgets('bubbles show sender, route, transport and status icon', (
      tester,
    ) async {
      await show(tester, const ChatScreen(chatId: 1));
      expect(find.text('Привіт!'), findsOneWidget);
      expect(find.text('Вітаю, як справи?'), findsOneWidget);
      expect(find.text('Невдала спроба'), findsOneWidget);

      Text meta(int id) =>
          tester.widget<Text>(find.byKey(ValueKey('meta-$id')));
      expect(meta(1).data, 'B (телефон) · opportunistic · TCP');
      expect(meta(2).data, 'B (телефон) · direct · TCP');
      expect(meta(3).data, 'B (телефон) · opportunistic · в черзі (офлайн)');

      Icon icon(int id) =>
          tester.widget<Icon>(find.byKey(ValueKey('status-$id')));
      expect(icon(1).icon, Icons.south_west); // received
      expect(icon(2).icon, Icons.done_all); // delivered
      expect(icon(3).icon, Icons.error_outline); // failed
      expect(icon(4).icon, Icons.schedule); // queued
      expect(find.byKey(const ValueKey('badge-B')), findsOneWidget);
    });

    testWidgets('composer states who the message is sent from', (tester) async {
      await show(tester, const ChatScreen(chatId: 1));
      expect(find.text('Від: B (телефон)'), findsOneWidget);
    });

    testWidgets('composer for an A chat shows A', (tester) async {
      await show(tester, const ChatScreen(chatId: 2));
      expect(find.text('Від: A (міст)'), findsOneWidget);
    });

    testWidgets('sending goes through the node', (tester) async {
      final node = FakeNode();
      await show(tester, const ChatScreen(chatId: 1), node: node);
      await tester.enterText(
        find.byKey(const ValueKey('composer-input')),
        '  Тест  ',
      );
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await tester.pump();
      expect(node.sent, [(1, 'Тест')]);
    });

    testWidgets('tapping a message shows hash and delivery timeline', (
      tester,
    ) async {
      await show(tester, const ChatScreen(chatId: 1));
      await tester.tap(find.text('Вітаю, як справи?'));
      await tester.pumpAndSettle();
      expect(find.text('Деталі повідомлення'), findsOneWidget);
      expect(find.text('ab12cd34' * 8), findsOneWidget);
      expect(find.textContaining('поставлено в чергу'), findsOneWidget);
      expect(find.text('відправлено'), findsWidgets);
      expect(find.text('доставлено'), findsWidgets);
    });
  });

  group('new chat', () {
    testWidgets('rejects a malformed address, accepts a valid one', (
      tester,
    ) async {
      final node = FakeNode();
      await show(tester, const NewChatScreen(), node: node);
      expect(find.text('Alice'), findsOneWidget); // known peer from announces
      await tester.enterText(
        find.byKey(const ValueKey('address-field')),
        'xyz',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('open-chat')));
      await tester.tap(find.byKey(const ValueKey('open-chat')));
      await tester.pump();
      expect(find.text('Адреса має бути 32 hex-символи'), findsOneWidget);
      expect(node.opened, isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey('address-field')),
        'a' * 32,
      );
      await tester.tap(find.byKey(const ValueKey('open-chat')));
      await tester.pump();
      expect(node.opened, ['a' * 32]);
    });

    testWidgets('tapping a known peer fills the address', (tester) async {
      await show(tester, const NewChatScreen());
      await tester.tap(find.text('Alice'));
      await tester.pump();
      expect(find.text('aa' * 16), findsWidgets);
    });
  });

  group('settings', () {
    testWidgets('shows a platform default device name', (tester) async {
      await show(tester, const SettingsScreen());
      await tester.pump();
      final f = tester.widget<TextField>(
        find.byKey(const ValueKey('device-name')),
      );
      expect(f.controller!.text, defaultDeviceName());
      expect(f.controller!.text, isNotEmpty);
    });

    testWidgets('shows address, public key, QR and server defaults', (
      tester,
    ) async {
      await show(tester, const SettingsScreen());
      await tester.pump();
      expect(find.byKey(const ValueKey('lxmf-address')), findsOneWidget);
      expect(find.text(fakeAddress), findsOneWidget);
      expect(find.text(fakePublicKey), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('public-key-qr')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byType(QrImageView), findsOneWidget);
      final host = tester.widget<TextField>(
        find.byKey(const ValueKey('server-host')),
      );
      expect(host.controller!.text, 'rns.ostapyrih.com');
      final port = tester.widget<TextField>(
        find.byKey(const ValueKey('server-port')),
      );
      expect(port.controller!.text, '4242');
    });

    testWidgets('saving the display name and the server call the node', (
      tester,
    ) async {
      final node = FakeNode();
      await show(tester, const SettingsScreen(), node: node);
      await tester.enterText(
        find.byKey(const ValueKey('display-name')),
        'Мій вузол',
      );
      await tester.tap(find.byKey(const ValueKey('save-name')));
      await tester.pump();
      expect(node.names, ['Мій вузол']);

      await tester.enterText(
        find.byKey(const ValueKey('server-host')),
        'rns.example.org',
      );
      await tester.enterText(find.byKey(const ValueKey('server-port')), '4343');
      await tester.ensureVisible(find.byKey(const ValueKey('apply-server')));
      await tester.tap(find.byKey(const ValueKey('apply-server')));
      await tester.pump();
      expect(node.servers, [('rns.example.org', 4343)]);
    });

    testWidgets('bridge switch says "буде доступно" and persists the setting', (
      tester,
    ) async {
      late AppDatabase adb;
      late Repo repo;
      await tester.runAsync(() async {
        adb = await AppDatabase.open(
          inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        repo = Repo(adb);
      });
      await show(tester, const SettingsScreen(), repo: repo);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('bridge-switch')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('буде доступно'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('bridge-switch')));
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('bridge-switch')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(await repo.bridgeEnabled(), isTrue);
        await adb.close();
      });
    });
  });

  testWidgets('copy address puts it on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await show(tester, const SettingsScreen());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.copy).first);
    await tester.pump();
    expect(copied, fakeAddress);
  });
}
