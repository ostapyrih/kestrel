import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'bridge/bridge_connection.dart';
import 'bridge/bridge_service.dart';
import 'l10n/strings.dart';
import 'node/identity_store.dart';
import 'node/node_service.dart';
import 'nomadnet/nomad_providers.dart';
import 'nomadnet/nomad_service.dart';
import 'nomadnet/nomad_store.dart';
import 'platform.dart';
import 'providers.dart';
import 'screens/chats_screen.dart';
import 'storage/database.dart';
import 'storage/repo.dart';
import 'update/update_bootstrap.dart';
import 'update/update_service.dart';
import 'update/update_ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initDatabaseFactory();
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
  final updates = await createUpdateService(repo)
    ..start();
  // The UI comes up immediately; the node starts in the background and the
  // connection indicator reports progress.
  unawaited(
    node.start().then((_) => bridge.start()).catchError((Object e) {
      debugPrint('node start failed: $e');
    }),
  );
  unawaited(nomad.start());
  runApp(
    ProviderScope(
      overrides: [
        repoProvider.overrideWithValue(repo),
        nodeProvider.overrideWithValue(node),
        bridgeProvider.overrideWithValue(bridge),
        nomadServiceProvider.overrideWithValue(nomad),
        updateServiceProvider.overrideWithValue(updates),
      ],
      child: const KestrelApp(),
    ),
  );
}

class KestrelApp extends StatelessWidget {
  const KestrelApp({super.key, this.home});

  static final _navigatorKey = GlobalKey<NavigatorState>();

  /// Overridable for tests and screenshots.
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kestrel',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      builder: (context, child) =>
          UpdateHost(navigatorKey: _navigatorKey, child: child),
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
