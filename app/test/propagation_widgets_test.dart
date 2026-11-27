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
  Uint8List? defaultNode,
  bool usingDefault = false,
  bool defaultDown = false,
}) => PropagationView(
  defaultNode: defaultNode,
  usingDefault: usingDefault,
  defaultUnreachable: defaultDown,
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
    testWidgets('compact: current node, details, Change; no node list', (
      tester,
    ) async {
      final a = _node(1, name: 'Near node', hops: 1);
      final b = _node(2, name: 'Far node', hops: 5);
      final node = FakeNode()..view = _view(nodes: [a, b], active: a.hash);
      await show(tester, const SettingsScreen(), node: node);
      await reveal(tester, 'mail-section');
      expect(find.text('Зараз: Near node'), findsOneWidget);
      expect(find.textContaining('стрибків: 1'), findsOneWidget);
      expect(find.textContaining('Far node'), findsNothing);
      expect(find.byKey(const ValueKey('mail-change')), findsOneWidget);
      expect(find.text('Змінити'), findsOneWidget);
      expect(find.text('Пошту ще не перевіряли'), findsOneWidget);
    });

    testWidgets('no node found yet', (tester) async {
      await show(tester, const SettingsScreen(), node: FakeNode());
      await reveal(tester, 'mail-section');
      expect(find.text('Вузол ще не знайдено'), findsOneWidget);
    });

    testWidgets('default node: labelled, unheard and unreachable states', (
      tester,
    ) async {
      final def = Uint8List.fromList(List.filled(16, 0xBC));
      final node = FakeNode()
        ..view = _view(active: def, defaultNode: def, usingDefault: true);
      await show(tester, const SettingsScreen(), node: node);
      await reveal(tester, 'mail-section');
      expect(find.textContaining('(типовий)'), findsOneWidget);
      expect(find.text('ще не чути'), findsOneWidget);

      final near = _node(1, name: 'Near node', hops: 1);
      node.view = _view(
        nodes: [near],
        active: near.hash,
        defaultNode: def,
        usingDefault: true,
        defaultDown: true,
      );
      node.viewChanges.add(node.view);
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Типовий вузол недоступний, використовуємо Near node'),
        findsOneWidget,
      );
    });

    testWidgets('pinned shows the pin', (tester) async {
      final b = _node(2, name: 'Far node', hops: 5);
      final node = FakeNode()
        ..view = _view(nodes: [b], active: b.hash, pinned: b.hash);
      await show(tester, const SettingsScreen(), node: node);
      await reveal(tester, 'mail-section');
      expect(find.text('Зараз: Far node (закріплений)'), findsOneWidget);
    });

    group('Change screen', () {
      final a = _node(1, name: 'Near node', hops: 1);
      final b = _node(2, name: 'Far node', hops: 5);
      final def = _node(3, name: 'Owner node', hops: 3);

      Future<FakeNode> open(
        WidgetTester tester, {
        Uint8List? pinned,
        bool usingDefault = true,
      }) async {
        final node = FakeNode()
          ..view = _view(
            nodes: [b, def, a],
            active: def.hash,
            pinned: pinned,
            defaultNode: def.hash,
            usingDefault: usingDefault,
          );
        await show(tester, const SettingsScreen(), node: node);
        await reveal(tester, 'mail-change');
        await tester.ensureVisible(find.byKey(const ValueKey('mail-change')));
        await tester.tap(find.byKey(const ValueKey('mail-change')));
        await tester.pumpAndSettle();
        return node;
      }

      testWidgets('sorted by hops, marks current and default', (tester) async {
        await open(tester);
        expect(find.text('Вузол розсилки'), findsOneWidget);
        final ys = [
          for (final n in [a, def, b])
            tester
                .getTopLeft(find.byKey(ValueKey('mail-node-${n.hashHex}')))
                .dy,
        ];
        expect(ys, orderedEquals([...ys]..sort()));
        expect(find.textContaining('зараз · типовий'), findsOneWidget);
      });

      testWidgets('search by name and by hash', (tester) async {
        await open(tester);
        await tester.enterText(
          find.byKey(const ValueKey('mail-search')),
          'far',
        );
        await tester.pump();
        expect(find.text('Far node'), findsOneWidget);
        expect(find.text('Near node'), findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('mail-search')),
          a.hashHex.substring(0, 6),
        );
        await tester.pump();
        expect(find.text('Near node'), findsOneWidget);
        expect(find.text('Far node'), findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('mail-search')),
          'zzz',
        );
        await tester.pump();
        expect(find.text('Нічого не знайдено'), findsOneWidget);
      });

      testWidgets('picking a node pins it and returns', (tester) async {
        final node = await open(tester);
        await tester.tap(find.byKey(ValueKey('mail-node-${b.hashHex}')));
        await tester.pumpAndSettle();
        expect(node.pinnedCalls, [b.hashHex]);
        expect(find.byKey(const ValueKey('mail-search')), findsNothing);
      });

      testWidgets('Automatic unpins', (tester) async {
        final node = await open(tester);
        await tester.tap(find.byKey(const ValueKey('mail-node-auto')));
        await tester.pumpAndSettle();
        expect(node.pinnedCalls, [null]);
      });

      testWidgets('Reset to default', (tester) async {
        final node = await open(tester, pinned: b.hash, usingDefault: false);
        await tester.tap(find.byKey(const ValueKey('mail-node-reset')));
        await tester.pumpAndSettle();
        expect(node.resetCalls, 1);
        expect(node.pinnedCalls, isEmpty);
      });

      testWidgets('picking the default node resets to it', (tester) async {
        final node = await open(tester, pinned: b.hash, usingDefault: false);
        await tester.tap(find.byKey(ValueKey('mail-node-${def.hashHex}')));
        await tester.pumpAndSettle();
        expect(node.resetCalls, 1);
        expect(node.pinnedCalls, isEmpty);
      });

      testWidgets('an unheard default and an unheard pin are listed', (
        tester,
      ) async {
        final p = Uint8List.fromList(List.filled(16, 0xAB));
        final d = Uint8List.fromList(List.filled(16, 0xBC));
        final node = FakeNode()
          ..view = _view(pinned: p, active: p, defaultNode: d);
        await show(tester, const SettingsScreen(), node: node);
        await reveal(tester, 'mail-change');
        await tester.ensureVisible(find.byKey(const ValueKey('mail-change')));
        await tester.tap(find.byKey(const ValueKey('mail-change')));
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey('mail-node-${toHex(p)}')), findsOneWidget);
        expect(find.byKey(ValueKey('mail-node-${toHex(d)}')), findsOneWidget);
        expect(find.textContaining('Невідомий вузол'), findsNWidgets(2));
      });

      testWidgets('English strings', (tester) async {
        final node = FakeNode()
          ..view = _view(
            nodes: [a],
            active: a.hash,
            defaultNode: a.hash,
            usingDefault: true,
          );
        await show(
          tester,
          const SettingsScreen(),
          node: node,
          locale: const Locale('en'),
        );
        await reveal(tester, 'mail-change');
        expect(find.text('Using: Near node (default)'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('mail-change')));
        await tester.tap(find.byKey(const ValueKey('mail-change')));
        await tester.pumpAndSettle();
        expect(find.text('Reset to default'), findsOneWidget);
        expect(find.text('Automatic (nearest node)'), findsOneWidget);
        expect(find.text('Search by name or hash'), findsOneWidget);
      });
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
