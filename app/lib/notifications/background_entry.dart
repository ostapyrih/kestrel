import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../bridge/bridge_connection.dart';
import '../bridge/bridge_service.dart';
import '../l10n/strings.dart';
import '../node/identity_store.dart';
import '../node/node_service.dart';
import '../platform.dart';
import '../storage/database.dart';
import '../storage/repo.dart';
import 'background_task.dart';
import 'local_notification_sink.dart';

/// The real [BackgroundSession]: the same node and bridge as the app, started
/// for one short check and then stopped.
class NodeBackgroundSession implements BackgroundSession {
  NodeBackgroundSession._(this._adb, this.repo, this.node, this.bridge);

  final AppDatabase _adb;
  @override
  final Repo repo;
  final NodeService node;
  final BridgeService bridge;

  static Future<NodeBackgroundSession> open() async {
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
      announceOnConnect: false,
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
    final s = NodeBackgroundSession._(adb, repo, node, bridge);
    unawaited(node.start().catchError((Object e) => debugPrint('bg node: $e')));
    return s;
  }

  @override
  Future<bool> connect(Duration timeout) async {
    final end = DateTime.now().add(timeout);
    try {
      await node.ready.timeout(timeout);
    } on Object {
      return false;
    }
    while (node.connection != NodeConnection.online) {
      if (DateTime.now().isAfter(end)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return true;
  }

  @override
  Future<void> syncInbox(Duration timeout) async {
    await node.syncMail().timeout(timeout);
  }

  @override
  Future<void> syncBridge(Duration timeout) async {
    if (!await repo.bridgeEnabled()) return;
    await bridge.start();
    final end = DateTime.now().add(timeout);
    var quiet = 0;
    // connected and no sync running for a moment = caught up
    while (DateTime.now().isBefore(end) && quiet < 4) {
      quiet = (bridge.status.connected && !bridge.syncing) ? quiet + 1 : 0;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  @override
  Future<void> close() async {
    for (final step in <Future<void> Function()>[
      bridge.vault.flushHistory,
      bridge.stop,
      node.stop,
      _adb.close,
    ]) {
      try {
        await step().timeout(const Duration(seconds: 2));
      } on Object catch (e) {
        debugPrint('bg close step failed: $e');
      }
    }
  }
}

/// Entry point of the BGTaskScheduler task (iOS): runs in a headless engine.
@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    final sink = LocalNotificationSink();
    await sink.init();
    final check = BackgroundInboxCheck(
      open: NodeBackgroundSession.open,
      sink: sink,
      lang: () => Strings.resolve(
        WidgetsBinding.instance.platformDispatcher.locale,
        Strings.supportedLocales,
      ).languageCode,
    );
    return check.run();
  });
}

/// Registers the periodic background check with iOS. Safe to call often (at
/// launch and whenever the app goes to the background): iOS keeps one pending
/// request per identifier and picks the time itself.
Future<void> scheduleIosInboxCheck() async {
  if (!Platform.isIOS) return;
  try {
    await Workmanager().initialize(backgroundCallbackDispatcher);
    await Workmanager().registerPeriodicTask(
      iosInboxTaskId,
      iosInboxTaskId,
      initialDelay: const Duration(minutes: 15),
    );
  } on Object catch (e) {
    debugPrint('background check scheduling failed: $e');
  }
}

/// Withdraws the background check (notifications switched off).
Future<void> cancelIosInboxCheck() async {
  if (!Platform.isIOS) return;
  try {
    await Workmanager().cancelByUniqueName(iosInboxTaskId);
  } on Object catch (e) {
    debugPrint('background check cancel failed: $e');
  }
}
