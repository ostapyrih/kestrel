import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/main.dart';
import 'package:kestrel/node/node_service.dart';
import 'package:kestrel/screens/chat_screen.dart';
import 'package:kestrel/screens/chats_screen.dart';
import 'package:kestrel/screens/settings_screen.dart';
import 'package:material_ui/material_ui.dart';

import 'support/fixtures.dart';

/// Renders the screens with real fonts and writes PNGs to
/// `../docs/screenshots/`. Opt in with `KESTREL_SCREENSHOTS=1`.
void main() {
  final enabled = Platform.environment['KESTREL_SCREENSHOTS'] == '1';
  final fontDir = Platform.environment['FLUTTER_ROOT'] != null
      ? '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts'
      : null;

  Future<void> loadFonts() async {
    Future<ByteData> read(String f) async =>
        ByteData.sublistView(await File('$fontDir/$f').readAsBytes());
    final roboto = FontLoader('Roboto')
      ..addFont(read('roboto-regular.ttf'))
      ..addFont(read('roboto-bold.ttf'))
      ..addFont(read('roboto-medium.ttf'));
    await roboto.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(read('materialicons-regular.otf'));
    await icons.load();
  }

  Future<void> shot(
    WidgetTester tester,
    Widget home,
    String name, {
    Future<void> Function()? before,
  }) async {
    final key = GlobalKey();
    tester.view.physicalSize = const Size(420 * 2, 860 * 2);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.localesTestValue = [const Locale('uk')];
    await tester.pumpWidget(
      ProviderScope(
        overrides: fixtureOverrides(conn: NodeConnection.online),
        child: RepaintBoundary(
          key: key,
          child: KestrelApp(home: home),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    if (before != null) await before();
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final f = File('../docs/screenshots/$name.png');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  setUpAll(() async {
    if (enabled && fontDir != null) await loadFonts();
  });

  testWidgets('screenshots', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    await shot(tester, const ChatsScreen(), 'chats');
    await shot(tester, const ChatScreen(chatId: 1), 'chat');
    await shot(tester, const SettingsScreen(), 'settings');
  }, skip: !enabled || fontDir == null);
}
