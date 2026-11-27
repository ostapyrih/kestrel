import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nativeapi/nativeapi.dart' as napi;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'bridge/bridge_connection.dart';
import 'bridge/bridge_service.dart';
import 'l10n/strings.dart';
import 'lora/lora_model.dart';
import 'lora/lora_providers.dart';
import 'lora/lora_service.dart';
import 'lora/lora_transports.dart';
import 'node/identity_store.dart';
import 'node/node_service.dart';
import 'desktop/desktop_settings.dart';
import 'desktop/desktop_shell.dart';
import 'desktop/desktop_strings.dart';
import 'desktop/native_desktop.dart';
import 'notifications/background_entry.dart';
import 'notifications/background_service.dart';
import 'notifications/local_notification_sink.dart';
import 'notifications/notification_host.dart';
import 'notifications/notification_providers.dart';
import 'notifications/notification_runtime.dart';
import 'notifications/notification_strings.dart';
import 'screens/chat_screen.dart';
import 'nomadnet/nomad_providers.dart';
import 'nomadnet/nomad_service.dart';
import 'nomadnet/nomad_store.dart';
import 'platform.dart';
import 'providers.dart';
import 'screens/chats_screen.dart';
import 'storage/database.dart';
import 'storage/repo.dart';
import 'update/update_bootstrap.dart';
import 'nomadnet/micron/micron_layout.dart';
import 'update/update_service.dart';
import 'update/update_ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initDatabaseFactory();
  registerMicronFontLicense();
  final dir = await getApplicationSupportDirectory();
  final adb = await AppDatabase.open(p.join(dir.path, 'kestrel.db'));
  final repo = Repo(adb);
  final rnsDir = Directory(p.join(dir.path, 'rns'));
  await rnsDir.create(recursive: true);
  final secrets = SecureSecretStore();
  final node = NodeService(
    repo: repo,
    secrets: secrets,
    rnsStorage: JsonFileStorage(rnsDir),
  );
  final bridge = BridgeService(
    repo: repo,
    ownDeviceId: () => toHex(node.identity.hash),
    identity: () => node.identity,
    sendAsB: node.sendMessage,
    secrets: secrets,
    apiFactory: (key, allowFallback) => BridgeConnection(
      rns: node.rns,
      identity: node.identity,
      bridgePublicKey: key,
      router: node.router,
      allowFallback: allowFallback,
    ),
  );
  node.bridge = bridge;
  final nomad = NomadService(node: node, store: NomadStore(adb));
  final lora = LoraService(
    store: LoraStore(repo),
    node: node,
    transports: PluginLoraTransports(),
  );
  // Closing the window hides it to the tray; every real exit (tray menu,
  // updater, setting off, Cmd+Q) goes through shutdown() and closes the
  // database cleanly.
  Future<void>? shuttingDown;
  late final BackgroundModeController background;
  Future<void> shutdown() => shuttingDown ??= () async {
    for (final step in <Future<void> Function()>[
      () => background.shutdown(),
      bridge.vault.flushHistory,
      bridge.stop,
      lora.stop, // radio off before the node goes away
      node.stop,
      adb.close,
    ]) {
      try {
        await step().timeout(const Duration(seconds: 2));
      } catch (e) {
        debugPrint('shutdown step failed: $e');
      }
    }
  }();
  // Notifications: local ones on every platform (no APNs, no FCM). A tap
  // opens its chat; a tap that launched the app is handled once the first
  // frame is up.
  void Function(int chatId)? openChat;
  final sink = LocalNotificationSink();
  final launchChat = await sink.init(onTap: (id) => openChat?.call(id));
  final focus = ChatFocus()..attach();
  final notifications = NotificationRuntime(
    repo: repo,
    sink: sink,
    focus: focus,
    lang: deviceLang,
    markRead: (id) async {
      await bridge.markRead(id).catchError((Object _) {});
      await repo.markRead(id);
    },
  )..start();
  background = BackgroundModeController(
    service: platformBackgroundService(),
    isOn: notifications.store.backgroundOn,
    title: () => notifText(deviceLang(), 'n_fg_title'),
    text: () => notifText(deviceLang(), 'n_fg_text'),
  );
  final shell = DesktopShell(
    desktop: isDesktop,
    window: NativeWindowHost(),
    tray: NativeTrayHost(),
    closeToTray: () async =>
        closeToTrayFrom(await repo.getSetting(closeToTrayKey)),
    shutdown: shutdown,
    exitProcess: () async {
      await ServicesBinding.instance.exitApplication(AppExitType.required);
    },
    labels: () {
      final lang = deviceLang();
      return TrayLabels(
        open: desktopText(lang, 'tray_open'),
        quit: desktopText(lang, 'tray_quit'),
        tooltip: (n) => n > 0
            ? desktopText(lang, 'tray_tooltip_unread', {'n': '$n'})
            : desktopText(lang, 'tray_tooltip'),
      );
    },
  );
  final updates =
      await createUpdateService(repo, exitApp: () => unawaited(shell.quit()))
        ..start();
  // The UI comes up immediately; the node starts in the background and the
  // connection indicator reports progress.
  unawaited(
    node.start().then((_) => bridge.start()).catchError((Object e) {
      debugPrint('node start failed: $e');
    }),
  );
  // Android: the foreground service keeps all of the above alive in the
  // background; the toggle in Settings starts and stops it.
  unawaited(background.apply());
  unawaited(
    repo
        .watch(notifications.store.backgroundOn)
        .forEach((_) => unawaited(background.apply())),
  );
  // iOS: periodic background checks, decided by the system
  if (Platform.isIOS) {
    unawaited(scheduleIosInboxCheck());
  }
  unawaited(nomad.start());
  unawaited(lora.start());
  // browsing history is uploaded in batches; send what is left on the way out
  AppLifecycleListener(
    onHide: () {
      unawaited(bridge.vault.flushHistory());
      if (Platform.isIOS) unawaited(scheduleIosInboxCheck());
    },
    onPause: () => unawaited(bridge.vault.flushHistory()),
  );
  if (isDesktop) {
    // exits the platform asks for (Cmd+Q, session end) close the database too
    AppLifecycleListener(
      onExitRequested: () async {
        await shutdown();
        return AppExitResponse.exit;
      },
      onDetach: () => unawaited(shutdown()),
    );
    unawaited(
      shell.start().then((_) {
        unawaited(
          repo
              .watch(() async {
                final chats = await repo.chats();
                return chats.fold<int>(0, (a, c) => a + c.unread);
              })
              .forEach((n) => unawaited(shell.setUnread(n))),
        );
        if (Platform.isMacOS) {
          // Dock click on a hidden window brings it back
          napi.Application.instance.addListener((e) {
            if (e is napi.ApplicationActivatedEvent) {
              unawaited(shell.showIfHidden());
            }
          });
        }
      }),
    );
  }
  final container = ProviderContainer(
    overrides: [
      repoProvider.overrideWithValue(repo),
      nodeProvider.overrideWithValue(node),
      bridgeProvider.overrideWithValue(bridge),
      nomadServiceProvider.overrideWithValue(nomad),
      loraControllerProvider.overrideWithValue(lora),
      updateServiceProvider.overrideWithValue(updates),
      chatFocusProvider.overrideWithValue(focus),
      notificationSinkProvider.overrideWithValue(sink),
      backgroundServiceProvider.overrideWithValue(background.service),
      backgroundModeProvider.overrideWithValue(background),
    ],
  );
  openChat = (id) {
    if (isDesktop) unawaited(shell.showWindow());
    container.read(selectedChatProvider.notifier).select(id);
    final nav = appNavigatorKey.currentState;
    final ctx = appNavigatorKey.currentContext;
    if (nav == null || ctx == null) return;
    if (MediaQuery.sizeOf(ctx).width >= wideLayoutBreakpoint) return;
    nav.popUntil((r) => r.isFirst);
    nav.push(MaterialPageRoute<void>(builder: (_) => ChatScreen(chatId: id)));
  };
  runApp(
    UncontrolledProviderScope(container: container, child: const KestrelApp()),
  );
  if (launchChat != null) {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => openChat?.call(launchChat),
    );
  }
}

/// The root navigator (notification taps navigate through it).
final appNavigatorKey = GlobalKey<NavigatorState>();

class KestrelApp extends StatelessWidget {
  const KestrelApp({super.key, this.home});

  /// Overridable for tests and screenshots.
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kestrel',
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      builder: (context, child) => NotificationHost(
        navigatorKey: appNavigatorKey,
        child: UpdateHost(navigatorKey: appNavigatorKey, child: child),
      ),
      localizationsDelegates: Strings.delegates,
      supportedLocales: Strings.supportedLocales,
      localeResolutionCallback: Strings.resolve,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: home ?? const ChatsScreen(),
    );
  }
}
