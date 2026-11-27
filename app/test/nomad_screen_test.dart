import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/node/node_service.dart';
import 'package:kestrel/nomadnet/micron/micron_view.dart';
import 'package:kestrel/nomadnet/nomad_providers.dart';
import 'package:kestrel/nomadnet/nomad_screen.dart';
import 'package:kestrel/nomadnet/nomad_service.dart';
import 'package:kestrel/nomadnet/nomad_store.dart';
import 'package:kestrel/screens/chats_screen.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/main.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fixtures.dart';
import 'support/nomad_fakes.dart';

const hA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const hB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase adb;
  late NomadStore store;
  late List<FakeFetch> requests;
  late NomadService service;

  Future<void> show(
    WidgetTester tester, {
    Size size = const Size(420, 860),
    Widget home = const NomadScreen(),
    Locale locale = const Locale('uk'),
  }) async {
    tester.platformDispatcher.localeTestValue = locale;
    tester.platformDispatcher.localesTestValue = [locale];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.runAsync(() async {
      adb = await AppDatabase.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      store = NomadStore(adb);
      requests = [];
      await store.upsertAnnounced(hA, name: 'Alpha Node', hops: 3, nowMs: 1000);
      await store.upsertAnnounced(hB, name: 'Beta Node', hops: 1, nowMs: 2000);
      service = NomadService(
        node: FakeNode(),
        store: store,
        saver: FakeSaver(),
        fetchOverride: (h, path, {data, identify = false}) {
          final f = FakeFetch(path, data, identify);
          requests.add(f);
          return f;
        },
      );
    });
    addTearDown(() => tester.runAsync(adb.close));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...fixtureOverrides(conn: NodeConnection.online),
          nomadServiceProvider.overrideWithValue(service),
        ],
        child: KestrelApp(home: home),
      ),
    );
    await settle(tester);
  }

  testWidgets('node list: sorted by last announce, search, favourites',
      (tester) async {
    await show(tester);
    final tiles = find.byWidgetPredicate(
      (w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('nn-node-'),
    );
    expect(tiles, findsNWidgets(2));
    // Beta announced later -> first
    expect(
      tester.getTopLeft(find.text('Beta Node')).dy,
      lessThan(tester.getTopLeft(find.text('Alpha Node')).dy),
    );
    await tester.enterText(find.byKey(const ValueKey('nn-search')), 'alp');
    await tester.pump();
    expect(find.text('Beta Node'), findsNothing);
    expect(find.text('Alpha Node'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('nn-search')), '');
    await tester.pump();

    // star Alpha: it moves to the top
    await tester.runAsync(() async {});
    await tester.tap(find.byKey(const ValueKey('nn-star-$hA')));
    await settle(tester);
    expect(
      tester.getTopLeft(find.text('Alpha Node')).dy,
      lessThan(tester.getTopLeft(find.text('Beta Node')).dy),
    );
    expect((await tester.runAsync(() => store.node(hA)))!.favourite, isTrue);
  });

  testWidgets('sort by distance and by name', (tester) async {
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('nn-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('За назвою'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Alpha Node')).dy,
      lessThan(tester.getTopLeft(find.text('Beta Node')).dy),
    );
    await tester.tap(find.byKey(const ValueKey('nn-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('За відстанню'));
    await tester.pumpAndSettle();
    // Beta has 1 hop, Alpha 3
    expect(
      tester.getTopLeft(find.text('Beta Node')).dy,
      lessThan(tester.getTopLeft(find.text('Alpha Node')).dy),
    );
  });

  testWidgets('narrow: tapping a node opens the browser and shows the page',
      (tester) async {
    await show(tester);
    await tester.tap(find.text('Beta Node'));
    await settle(tester);
    expect(requests.single.path, '/page/index.mu');
    expect(find.byKey(const ValueKey('nn-progress')), findsOneWidget);
    requests.single.progressC.add(
      const NomadProgress(NomadPhase.connecting, hops: 1),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('nn-status')), findsOneWidget);
    expect(find.textContaining('Зʼєднання'), findsWidgets);
    expect(find.textContaining('1 стрибок'), findsWidgets);
    requests.single.respond('>Welcome\n`[Next`:/page/n.mu]');
    await settle(tester);
    expect(find.byType(MicronView), findsOneWidget);
    expect(find.text('Welcome'), findsWidgets);
    expect(find.byKey(const ValueKey('nn-progress')), findsNothing);
  });

  testWidgets('failure banner with retry', (tester) async {
    await show(tester);
    await tester.tap(find.text('Beta Node'));
    await settle(tester);
    requests.single.fail(NomadFailure.noPath);
    await settle(tester);
    expect(find.byKey(const ValueKey('nn-failure')), findsOneWidget);
    expect(find.textContaining('Шлях до вузла не знайдено'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nn-retry')));
    await settle(tester);
    expect(requests.length, 2);
  });

  testWidgets('address bar: malformed address is reported, valid one loads',
      (tester) async {
    await show(tester);
    await tester.enterText(find.byKey(const ValueKey('nn-address-list')), 'zzz');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.textContaining('Некоректна адреса'), findsOneWidget);
    expect(requests, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('nn-address-list')),
      '$hA:/page/x.mu',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(requests.single.path, '/page/x.mu');
  });

  testWidgets('English strings', (tester) async {
    await show(tester, locale: const Locale('en'));
    expect(find.text('Nodes'), findsOneWidget);
    expect(find.text('Bookmarks'), findsOneWidget);
  });

  testWidgets('wide: list and browser side by side, no route push',
      (tester) async {
    await show(tester, size: const Size(1200, 800));
    expect(find.byType(NodeListPane), findsOneWidget);
    expect(find.byType(BrowserPane), findsOneWidget);
    expect(find.text('Оберіть вузол зі списку або введіть адресу'),
        findsOneWidget);
    await tester.tap(find.text('Beta Node'));
    await settle(tester);
    requests.single.respond('>Hello\nbody');
    await settle(tester);
    expect(find.byType(NomadBrowserScreen), findsNothing);
    expect(find.byType(NodeListPane), findsOneWidget);
    expect(find.byType(MicronView), findsOneWidget);
    // back is disabled on the first page
    final back = tester.widget<IconButton>(find.byKey(const ValueKey('nn-back')));
    expect(back.onPressed, isNull);
  });

  testWidgets('entry point in the chat list opens the pages screen',
      (tester) async {
    await show(tester, home: const ChatsScreen());
    await tester.tap(find.byKey(const ValueKey('open-pages')));
    await settle(tester);
    expect(find.byType(NomadScreen), findsOneWidget);
  });

  testWidgets('copy address puts the URL on the clipboard', (tester) async {
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
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await show(tester, size: const Size(1200, 800));
    await tester.tap(find.text('Beta Node'));
    await settle(tester);
    requests.single.respond('>T');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('nn-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Копіювати адресу'));
    await tester.pumpAndSettle();
    expect(copied, '$hB:/page/index.mu');
  });

  testWidgets('menu: wrap long lines and zoom are saved per node', (
    tester,
  ) async {
    await show(tester, size: const Size(1200, 800));
    await tester.tap(find.text('Beta Node'));
    await settle(tester);
    requests.single.respond('>T
body');
    await settle(tester);
    Future<void> pick(String text) async {
      await tester.tap(find.byKey(const ValueKey('nn-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(text));
      await settle(tester);
    }

    expect(tester.widget<MicronView>(find.byType(MicronView)).wrapAll, isFalse);
    await pick('Переносити довгі рядки');
    expect(tester.widget<MicronView>(find.byType(MicronView)).wrapAll, isTrue);
    await pick('Збільшити текст');
    expect(tester.widget<MicronView>(find.byType(MicronView)).zoom, greaterThan(1));
    final row = await tester.runAsync(() => store.node(hB));
    expect(row!.wrapAll, isTrue);
    expect(row.fontScale, greaterThan(1));
    await pick('Підібрати за шириною');
    expect(tester.widget<MicronView>(find.byType(MicronView)).zoom, 1);
  });
}

/// Lets async work (sqlite on a real isolate, streams) finish.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}
