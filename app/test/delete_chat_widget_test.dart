import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/bridge/bridge_connection.dart';
import 'package:kestrel/main.dart';
import 'package:kestrel/node/node_service.dart';
import 'package:kestrel/screens/chat_screen.dart';
import 'package:kestrel/screens/chats_screen.dart';
import 'package:kestrel/screens/delete_chat.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:material_ui/material_ui.dart';

import 'support/fixtures.dart';

void main() {
  late FakeNode node;

  Future<void> show(
    WidgetTester tester,
    Widget home, {
    bool bridgeMode = true,
    bool withRemote = false,
    Locale locale = const Locale('en'),
  }) async {
    tester.platformDispatcher.localeTestValue = locale;
    tester.platformDispatcher.localesTestValue = [locale];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(840, 1720);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: fixtureOverrides(
          conn: NodeConnection.online,
          node: node,
          bridgeStatus: const BridgeStatus(BridgeState.connected),
          bridgeConfigured: bridgeMode,
          withRemote: withRemote,
        ),
        child: KestrelApp(home: home),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  setUp(() => node = FakeNode());

  test('RRC rooms are never deletable', () {
    final rrc = ChatRow(
      id: 9,
      accountIdentity: 'A',
      kind: 'rrc',
      peerHash: null,
      title: 'room',
      lastTs: null,
      unread: 0,
    );
    expect(isDeletable(rrc), isFalse);
    expect(isDeletable(fixtureChats.first), isTrue);
  });

  group('chat list', () {
    testWidgets('long-press selects, more taps add, delete asks first', (
      tester,
    ) async {
      await show(tester, const ChatsScreen());
      await tester.longPress(find.text('Alice'));
      await tester.pump();
      expect(find.text('Selected: 1'), findsOneWidget);
      // a tap now toggles instead of opening the chat
      await tester.tap(find.text('Marichka'));
      await tester.pump();
      expect(find.text('Selected: 2'), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
      await tester.tap(find.byKey(const ValueKey('select-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('delete-chat-dialog')), findsOneWidget);
      expect(find.text('Delete 2 chats?'), findsOneWidget);
      // says what happens to each kind
      expect(find.byKey(const ValueKey('delete-b-body')), findsOneWidget);
      expect(find.byKey(const ValueKey('delete-b-vault')), findsOneWidget);
      expect(find.byKey(const ValueKey('delete-a-body')), findsOneWidget);
      expect(
        find.textContaining('Delete for all devices and in MeshChatX'),
        findsOneWidget,
      );
      expect(node.deleted, isEmpty); // nothing before the confirmation
      await tester.tap(find.byKey(const ValueKey('delete-confirm')));
      await tester.pumpAndSettle();
      expect(node.deleted, [
        [1, 2],
      ]);
      // selection mode ended
      expect(find.text('Selected: 2'), findsNothing);
    });

    testWidgets('Cancel is the default focus and deletes nothing', (
      tester,
    ) async {
      await show(tester, const ChatsScreen());
      await tester.longPress(find.text('Alice'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('select-delete')));
      await tester.pumpAndSettle();
      final cancel = tester.widget<TextButton>(
        find.byKey(const ValueKey('delete-cancel')),
      );
      expect(cancel.autofocus, isTrue);
      final confirm = tester.widget<TextButton>(
        find.byKey(const ValueKey('delete-confirm')),
      );
      expect(confirm.autofocus, isFalse);
      await tester.tap(find.byKey(const ValueKey('delete-cancel')));
      await tester.pumpAndSettle();
      expect(node.deleted, isEmpty);
      expect(find.text('Selected: 1'), findsOneWidget); // still selecting
    });

    testWidgets('the dialog names the unsent messages that get cancelled', (
      tester,
    ) async {
      node.unsent = 3;
      await show(tester, const ChatsScreen());
      await tester.longPress(find.text('Alice'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('select-delete')));
      await tester.pumpAndSettle();
      expect(
        find.text('3 unsent message(s) will be cancelled.'),
        findsOneWidget,
      );
    });

    testWidgets('bridge off: no mention of other devices', (tester) async {
      await show(tester, const ChatsScreen(), bridgeMode: false);
      await tester.longPress(find.text('Alice'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('select-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('delete-b-body')), findsOneWidget);
      expect(find.byKey(const ValueKey('delete-b-vault')), findsNothing);
    });

    testWidgets('an old bridge: A delete is disabled with an explanation', (
      tester,
    ) async {
      node.deleteReason = 'delete_a_old_bridge';
      await show(tester, const ChatsScreen());
      await tester.longPress(find.text('Marichka'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('select-delete')));
      await tester.pumpAndSettle();
      expect(
        find.text('This bridge is too old to delete chats. Update the bridge.'),
        findsOneWidget,
      );
      final confirm = tester.widget<TextButton>(
        find.byKey(const ValueKey('delete-confirm')),
      );
      expect(confirm.onPressed, isNull);
      expect(node.deleted, isEmpty);
    });

    testWidgets('right click opens a context menu with the delete action', (
      tester,
    ) async {
      await show(tester, const ChatsScreen());
      final at = tester.getCenter(find.text('Alice'));
      final g = await tester.startGesture(
        at,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-delete')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('menu-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('delete-chat-dialog')), findsOneWidget);
      expect(find.text('Delete chat "Alice"?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('delete-confirm')));
      await tester.pumpAndSettle();
      expect(node.deleted, [
        [1],
      ]);
    });

    testWidgets('a read-only chat of another device: deleted everywhere, '
        'including that device', (tester) async {
      await show(tester, const ChatsScreen(), withRemote: true);
      await tester.longPress(find.text('Remote peer'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('select-delete')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Delete this chat on all devices, including iPhone',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a remote chat cannot be deleted without the vault', (
      tester,
    ) async {
      node.deleteReason = 'delete_remote_no_vault';
      await show(tester, const ChatsScreen(), withRemote: true);
      await tester.longPress(find.text('Remote peer'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('select-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('delete-blocked')), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('delete-confirm')))
            .onPressed,
        isNull,
      );
    });
  });

  group('chat screen', () {
    testWidgets('the menu has "Delete chat" and asks first', (tester) async {
      await show(tester, const ChatScreen(chatId: 1));
      await tester.tap(find.byKey(const ValueKey('chat-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-delete-chat')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('delete-chat-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('delete-confirm')));
      await tester.pumpAndSettle();
      expect(node.deleted, [
        [1],
      ]);
    });

    testWidgets('the menu item is disabled with the reason', (tester) async {
      node.deleteReason = 'delete_a_offline';
      await show(tester, const ChatScreen(chatId: 2));
      await tester.tap(find.byKey(const ValueKey('chat-menu')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The bridge is not connected'),
        findsOneWidget,
      );
      final item = tester.widget<PopupMenuItem<String>>(
        find.byKey(const ValueKey('menu-delete-chat')),
      );
      expect(item.enabled, isFalse);
    });
  });
}
