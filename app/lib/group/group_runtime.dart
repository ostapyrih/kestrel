import 'dart:async';

import 'package:kestrel_rns/kestrel_rns.dart';

import '../nomadnet/browser_sync.dart';
import 'history_backfill.dart';
import '../storage/repo.dart';
import 'group_service.dart';

/// Runs the device sync of a group of two or more devices: the LXMF router of
/// the hidden device key, [DeviceSync] (records between the devices), the
/// announcer election and the application of records to the database.
///
/// A single-device install never starts it (no extra announces, no stamps).
class GroupRuntime {
  GroupRuntime({
    required this.rns,
    required this.repo,
    required this.group,
    required this.groupRouter,
    required this.storage,
    required this.routerConfig,
    required this.internet,
    required this.onRole,
    this.onName,
    this.onIdentity,
    this.browser,
    this.presenceInterval = const Duration(seconds: 10),
  });

  final Reticulum rns;
  final Repo repo;
  final GroupService group;

  /// The router of the group identity G.
  final LxmRouter groupRouter;
  final KestrelStorage storage;
  final LxmRouterConfig routerConfig;

  /// True while this device reaches the internet (a TCP interface is online).
  final bool Function() internet;

  /// Announcer role changed: (de)activate announces, path-request answers and
  /// the propagation inbox of G, and announce immediately when true.
  final FutureOr<void> Function(bool announcing) onRole;
  final void Function(String name)? onName;

  /// A sibling moved the group to a new G: the owner switches router and
  /// announcer (and restarts the runtime).
  final Future<void> Function(IdentityChange change)? onIdentity;
  final BrowserSyncStore? browser;
  final Duration presenceInterval;

  late LxmRouter deviceRouter;
  late DeviceSync sync;
  late GroupAnnouncer announcer;

  /// History backfill: serves siblings, requests it on a freshly paired device.
  late DeviceBackfill backfill;
  Timer? _pump;
  bool _started = false;

  bool get isAnnouncer => announcer.isAnnouncer;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    deviceRouter = await LxmRouter.start(
      rns,
      group.deviceIdentity,
      config: routerConfig,
    );
    deviceRouter
      ..setDefaultNode(groupRouter.defaultNode)
      ..setPinnedNode(groupRouter.pinnedNode)
      ..fallbackToPropagation = true
      ..setSyncInterval(const Duration(minutes: 2));
    sync = DeviceSync(
      rns: rns,
      router: deviceRouter,
      deviceKey: group.deviceIdentity,
      state: group.state,
      store: KestrelSyncStore(storage),
      group: groupRouter.destination,
      onIdentity: onIdentity,
      onRecord: _apply,
      onStateChanged: () {
        unawaited(group.persist());
        final n = group.state.displayName;
        if (n.isNotEmpty && n != groupRouter.displayName) onName?.call(n);
      },
    );
    await sync.start();
    backfill = DeviceBackfill(
      sync: sync,
      storage: storage,
      source: AppBackfillSource(repo),
      sink: AppBackfillSink(repo, browser: browser),
    );
    await backfill.init();
    sync.rememberSiblings();
    announcer = GroupAnnouncer(
      rns: rns,
      deviceKey: group.deviceIdentity,
      state: group.state,
      internet: internet,
      onRole: (on) async {
        await onRole(on);
        if (on) unawaited(sync.announceGroup(groupRouter));
      },
      interval: presenceInterval,
      deadAfter: presenceInterval * 3 + const Duration(seconds: 5),
    );
    await announcer.start();
    _pump = Timer.periodic(const Duration(seconds: 20), (_) => pumpBrowser());
    unawaited(announceDevice());
  }

  /// Announces the device key's destinations (sync channel + presence),
  /// spaced out: transports hold announce bursts of a young interface.
  Future<void> announceDevice() async {
    try {
      await deviceRouter.announce();
      await Future<void>.delayed(const Duration(seconds: 2));
      await announcer.announcePresence();
    } on Object {
      // best effort
    }
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _pump?.cancel();
    await backfill.stop();
    await announcer.stop();
    await sync.stop();
    rns.transport.deregisterDestination(deviceRouter.destination);
    await deviceRouter.stop();
  }

  // ----------------------------------------------------------------- apply

  Future<void> _apply(SyncRecord r) async {
    try {
      final d = r.data;
      switch (r.kind) {
        case SyncKind.messages:
          if (d is Map) await repo.applySyncedMessage(d);
        case SyncKind.deleteChat:
          if (d is Map && d['peer'] is String && d['before_ts'] is num) {
            await repo.applySyncedDelete(
              d['peer']! as String,
              ((d['before_ts']! as num) * 1000).ceil(),
            );
          }
        case SyncKind.read:
          if (d is Map && d['peer'] is String) {
            final id = await repo.findChatId('B', d['peer']! as String);
            if (id != null) await repo.markRead(id);
          }
        case SyncKind.browser:
          final ops = d is Map ? d['ops'] : null;
          if (ops is List) await browser?.apply(ops);
        case SyncKind.name:
          final n = group.state.displayName;
          if (n.isNotEmpty) onName?.call(n);
      }
    } on Object {
      // one bad record never stops the sync
    }
  }

  // --------------------------------------------------------------- publish

  /// A message this device received (announcer: forwarded to the siblings)
  /// or sent, with its delivery [state] for outgoing ones.
  Future<void> publishMessage({
    required String hash,
    required String peer,
    String? peerName,
    required bool incoming,
    required String text,
    String? title,
    required int tsMs,
    String? route,
    String? state,
  }) => sync.publish(SyncKind.messages, {
    'hash': hash,
    'peer': peer,
    'peer_name': ?peerName,
    'incoming': incoming,
    'text': text,
    'title': ?title,
    'ts': tsMs,
    'route': ?route,
    'state': ?state,
  });

  Future<void> publishDelete(String peer, int beforeTsMs) => sync.publish(
    SyncKind.deleteChat,
    {'peer': peer, 'before_ts': beforeTsMs / 1000},
  );

  Future<void> publishRead(String peer) =>
      sync.publish(SyncKind.read, {'peer': peer});

  /// Uploads waiting browser data (bookmarks, favourites, settings, history)
  /// as one record and marks it as sent.
  Future<void> pumpBrowser() async {
    final b = browser;
    if (b == null || !_started) return;
    try {
      final waiting = await b.pending(
        limit: 200,
        historyMinAgeMs: const Duration(minutes: 3).inMilliseconds,
      );
      if (waiting.isEmpty) return;
      await sync.publish(SyncKind.browser, {
        'ops': [for (final w in waiting) w.op],
      });
      await BrowserSyncStore.completeMarks(b.adb.db, [
        for (final w in waiting) w.mark,
      ]);
    } on Object {
      // retried by the next round
    }
  }
}
