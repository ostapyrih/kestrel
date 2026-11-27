import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/main.dart';
import 'package:kestrel/node/node_service.dart';
import 'package:kestrel/screens/chat_screen.dart';
import 'package:kestrel/screens/settings_screen.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fixtures.dart';

LxmPropagationNode _node(
  int seed, {
  String? name,
  int hops = 2,
  bool enabled = true,
}) => LxmPropagationNode(
  hash: Uint8List.fromList(List.filled(16, seed)),
  data: PropagationNodeData.parse(
    PropagationNodeData.pack(name: name, enabled: enabled, stampCost: 16),
  )!,
  hops: hops,
  lastSeen: DateTime.now().subtract(const Duration(minutes: 5)),
);

PropagationView _view({
  List<LxmPropagationNode> nodes = const [],
  Uint8List? active,
  Uint8List? pinned,
  LxmSyncProgress progress = const LxmSyncProgress(phase: LxmSyncPhase.idle),
  LxmSyncResult? last,
  bool fallback = true,
  int interval = 15,
}) => PropagationView(
  nodes: nodes,
  active: active,
  pinned: pinned,
  progress: progress,
  lastSync: last,
  fallback: fallback,
  intervalMinutes: interval,
);

void main() {
  setUpAll(sqfliteFfiInit);

  Future<void> show(
    WidgetTester tester,
    Widget home, {
    required FakeNode node,
    Locale locale = const Locale('uk'),
    List<MessageRow>? messages,
  }) async {
    tester.platformDispatcher.localeTestValue = locale;
    tester.platformDispatcher.localesTestValue = [locale];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(840, 5000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...fixtureOverrides(
            conn: NodeConnection.online,
            node: node,
            chat1Messages: messages,
          ),
        ],
        child: KestrelApp(home: home),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> reveal(WidgetTester tester, String key) async {
    await tester.scrollUntilVisible(
      find.byKey(ValueKey(key)),
      300,
      scrollable: find.byType(Scrollable).first,
    );
  }

  group('Settings: mail via node', () {
    testWidgets('empty: no node heard yet, automatic selected', (tester) async {
      final node = FakeNode();
      await show(tester, const SettingsScreen(), node: node);
      await reveal(tester, 'mail-section');
      expect(find.text('Пошта через вузол'), findsOneWidget);
      expect(find.byKey(const ValueKey('mail-nodes-empty')), findsOneWidget);
      expect(find.text('Вузол ще не знайдено'), findsOneWidget);
      expect(find.text('Пошту ще не перевіряли'), findsOneWidget);
    });

    testWidgets('lists known nodes; picking one pins it, auto unpins', (
      tester,
    ) async {
      final a = _node(1, name: 'Near node', hops: 1);
      final b = _node(2, name: 'Far node', hops: 5);
      final node = FakeNode()..view = _view(nodes: [a, b], active: a.hash);
      await show(tester, const SettingsScreen(), node: node);
      await reveal(tester, 'mail-section');
      expect(find.text('Near node'), findsWidgets);
      expect(find.text('Зараз: Near node'), findsOneWidget);
      expect(find.textContaining('стрибків: 5'), findsOneWidget);
      expect(find.textContaining('вартість штампа 16'), findsWidgets);

      await tester.ensureVisible(
        find.byKey(ValueKey('mail-node-${b.hashHex}')),
      );
      await tester.tap(find.byKey(ValueKey('mail-node-${b.hashHex}')));
      await tester.pump();
      expect(node.pinnedCalls, [b.hashHex]);

      // pinned view: current node shows the pin, auto unpins
      node.view = _view(nodes: [a, b], active: b.hash, pinned: b.hash);
      node.viewChanges.add(node.view);
      await tester.pump();
      await tester.pump();
      expect(find.text('Зараз: Far node (закріплений)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mail-node-auto')));
      await tester.pump();
      expect(node.pinnedCalls.last, isNull);
    });

    testWidgets('a pinned node nobody has heard is still listed', (
      tester,
    ) async {
      final p = Uint8List.fromList(List.filled(16, 0xAB));
      final node = FakeNode()..view = _view(pinned: p, active: p);
      await show(tester, const SettingsScreen(), node: node);
      await reveal(tester, 'mail-section');
      expect(find.byKey(ValueKey('mail-node-${toHex(p)}')), findsOneWidget);
      expect(find.textContaining('Невідомий вузол'), findsOneWidget);
    });

    testWidgets('interval and fallback toggle are applied', (tester) async {
      final node = FakeNode();
      await show(tester, const SettingsScreen(), node: node);
      await reveal(tester, 'mail-interval');
      await tester.tap(find.byKey(const ValueKey('mail-interval')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('кожні 30 хв').last);
      await tester.pumpAndSettle();
      expect(node.intervalCalls, [30]);

      await reveal(tester, 'mail-fallback-switch');
      await tester.tap(find.byKey(const ValueKey('mail-fallback-switch')));
      await tester.pump();
      expect(node.fallbackCalls, [false]);
    });

    testWidgets('Check mail now syncs; disabled and shows progress meanwhile', (
      tester,
    ) async {
      final node = FakeNode();
      await show(tester, const SettingsScreen(), node: node);
      await reveal(tester, 'mail-check-now');
      await tester.ensureVisible(find.byKey(const ValueKey('mail-check-now')));
      await tester.tap(find.byKey(const ValueKey('mail-check-now')));
      await tester.pump();
      expect(node.syncCalls, 1);

      node.view = _view(
        progress: const LxmSyncProgress(
          phase: LxmSyncPhase.receiving,
          progress: 0.5,
        ),
      );
      node.viewChanges.add(node.view);
      await tester.pump();
      await tester.pump();
      final btn = tester.widget<ButtonStyleButton>(
        find.byKey(const ValueKey('mail-check-now')),
      );
      expect(btn.onPressed, isNull);
      expect(find.text('Завантажуємо листи... 50%'), findsOneWidget);
    });

    testWidgets('last result: success and error texts', (tester) async {
      final node = FakeNode()
        ..view = _view(
          last: LxmSyncResult(
            error: LxmSyncError.none,
            at: DateTime.now(),
            delivered: 3,
          ),
        );
      await show(tester, const SettingsScreen(), node: node);
      await reveal(tester, 'mail-last');
      expect(find.textContaining('нових листів: 3'), findsOneWidget);
      node.view = _view(
        last: LxmSyncResult(error: LxmSyncError.noPath, at: DateTime.now()),
      );
      node.viewChanges.add(node.view);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('немає шляху до вузла'), findsOneWidget);
    });

    testWidgets('English strings', (tester) async {
      final a = _node(1, name: 'Near node', hops: 1);
      final node = FakeNode()
        ..view = _view(
          nodes: [a],
          active: a.hash,
          last: LxmSyncResult(
            error: LxmSyncError.none,
            at: DateTime.now(),
            delivered: 1,
            remaining: 2,
          ),
        );
      await show(
        tester,
        const SettingsScreen(),
        node: node,
        locale: const Locale('en'),
      );
      await reveal(tester, 'mail-section');
      expect(find.text('Mail via node'), findsOneWidget);
      expect(find.text('Automatic (nearest node)'), findsOneWidget);
      expect(find.text('Using: Near node'), findsOneWidget);
      expect(find.text('Check mail now'), findsOneWidget);
      expect(
        find.textContaining('new messages: 1, still on the node: 2'),
        findsOneWidget,
      );
    });
  });

  group('Chat: via node', () {
    MessageRow msg(int id, String route) => MessageRow(
      id: id,
      chatId: 1,
      direction: 'out',
      lxmfHash: 'ab' * 16,
      text: 'offline text $id',
      ts: DateTime(2026, 11, 25, 12).millisecondsSinceEpoch,
      senderIdentity: 'B',
      route: route,
      transport: 'tcp',
      status: 'sent',
      error: null,
      signatureValid: null,
      originDevice: null,
    );

    testWidgets('status line says "via node" for propagated messages', (
      tester,
    ) async {
      await show(
        tester,
        const ChatScreen(chatId: 1),
        node: FakeNode(),
        messages: [msg(11, 'propagated')],
      );
      final t = tester.widget<Text>(find.byKey(const ValueKey('meta-11')));
      expect(t.data, contains('через вузол'));
      expect(t.data, isNot(contains('propagated')));
    });

    testWidgets('English: "via node"', (tester) async {
      await show(
        tester,
        const ChatScreen(chatId: 1),
        node: FakeNode(),
        locale: const Locale('en'),
        messages: [msg(11, 'propagated')],
      );
      final t = tester.widget<Text>(find.byKey(const ValueKey('meta-11')));
      expect(t.data, contains('via node'));
    });

    testWidgets('"send via node" appears only when a node is known', (
      tester,
    ) async {
      final plain = FakeNode();
      await show(tester, const ChatScreen(chatId: 1), node: plain);
      expect(find.byKey(const ValueKey('composer-send-node')), findsNothing);
    });

    testWidgets('"send via node" sends with viaNode', (tester) async {
      final a = _node(1, name: 'N', hops: 1);
      final node = FakeNode()..view = _view(nodes: [a], active: a.hash);
      await show(tester, const ChatScreen(chatId: 1), node: node);
      await tester.enterText(
        find.byKey(const ValueKey('composer-input')),
        'hello later',
      );
      await tester.tap(find.byKey(const ValueKey('composer-send-node')));
      await tester.pump();
      expect(node.viaNodeSent, [(1, 'hello later')]);
    });
  });
}
