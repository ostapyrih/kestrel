import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'l10n/strings.dart';
import 'node/identity_store.dart';
import 'node/node_service.dart';
import 'platform.dart';
import 'providers.dart';
import 'screens/chats_screen.dart';
import 'storage/database.dart';
import 'storage/repo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initDatabaseFactory();
  final dir = await getApplicationSupportDirectory();
  final adb = await AppDatabase.open(p.join(dir.path, 'kestrel.db'));
  final repo = Repo(adb);
  final rnsDir = Directory(p.join(dir.path, 'rns'));
  await rnsDir.create(recursive: true);
  final node = NodeService(
    repo: repo,
    secrets: SecureSecretStore(),
    rnsStorage: JsonFileStorage(rnsDir),
  );
  // The UI comes up immediately; the node starts in the background and the
  // connection indicator reports progress.
  unawaited(
    node.start().catchError((Object e) {
      debugPrint('node start failed: $e');
    }),
  );
  runApp(
    ProviderScope(
      overrides: [
        repoProvider.overrideWithValue(repo),
        nodeProvider.overrideWithValue(node),
      ],
      child: const KestrelApp(),
    ),
  );
}

class KestrelApp extends StatelessWidget {
  const KestrelApp({super.key, this.home});

  /// Overridable for tests and screenshots.
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kestrel',
      debugShowCheckedModeBanner: false,
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
