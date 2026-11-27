import 'dart:async';

import 'package:flutter/foundation.dart';

import '../storage/repo.dart';
import 'notification_coordinator.dart';
import 'notification_models.dart';
import 'notification_prefs_store.dart';
import 'notification_strings.dart';

/// BGTaskScheduler identifier (also listed in Info.plist). iOS decides when,
/// and whether, it runs.
const iosInboxTaskId = 'com.ostapyrih.kestrel.inbox-check';

/// What one background check needs from the app: a connected node, the
/// propagation inbox and the bridge. Implemented by the real services
/// (`NodeBackgroundSession`) and by a fake in tests.
abstract class BackgroundSession {
  Repo get repo;

  /// Waits (at most [timeout]) until the network connection is up; false if
  /// it is not.
  Future<bool> connect(Duration timeout);

  /// Checks the propagation node's inbox. Messages land in [repo] and show up
  /// on [Repo.incomingMessages].
  Future<void> syncInbox(Duration timeout);

  /// Lets the bridge catch up (nothing when the bridge is off).
  Future<void> syncBridge(Duration timeout);

  /// Stops everything and closes the database.
  Future<void> close();
}

/// Nobody is looking at the app during a background check.
class _NoFocus implements AppFocus {
  @override
  bool get appActive => false;
  @override
  int? get openChatId => null;
}

/// The short inbox check that runs when iOS wakes the app in the background:
/// connect, sync the propagation inbox and the bridge within a time budget,
/// post local notifications for what arrived, then shut down gracefully.
class BackgroundInboxCheck {
  BackgroundInboxCheck({
    required this.open,
    required this.sink,
    required this.lang,
    this.budget = const Duration(seconds: 25),
  });

  /// Opens the session (database, node, bridge).
  final Future<BackgroundSession> Function() open;
  final NotificationSink sink;
  final String Function() lang;

  /// Everything, including shutdown, must fit in this (iOS gives about 30 s).
  final Duration budget;

  int notified = 0;

  /// Runs one check; true if it finished its work, false if it ran out of
  /// time or could not connect. Never throws.
  Future<bool> run() async {
    final clock = Stopwatch()..start();
    Duration left() => budget - clock.elapsed - const Duration(seconds: 4);

    BackgroundSession? session;
    final pending = <Future<void>>[];
    StreamSubscription<IncomingMessage>? sub;
    var complete = false;
    try {
      session = await open().timeout(budget);
      final repo = session.repo;
      final coordinator = NotificationCoordinator(
        sink: sink,
        prefs: NotificationPrefsStore(repo).load,
        focus: _NoFocus(),
        text: () => notificationTextFor(lang()),
      );
      sub = repo.incomingMessages.listen((m) {
        pending.add(
          coordinator.onIncoming(m).then((d) {
            if (d == NotifyDecision.show) notified++;
          }),
        );
      });
      final t1 = _cap(left(), 10);
      if (await _bounded(session.connect(t1), false, t1)) {
        final t2 = _cap(left(), 18);
        await _bounded(session.syncInbox(t2), null, t2);
        if (left() > Duration.zero) {
          final t3 = _cap(left(), 12);
          await _bounded(session.syncBridge(t3), null, t3);
        }
        complete = left() > Duration.zero;
      }
    } on Object catch (e) {
      debugPrint('background check failed: $e');
    } finally {
      try {
        await Future.wait(pending).timeout(const Duration(seconds: 3));
      } on Object {
        // a notification that did not get out in time is lost, not fatal
      }
      await sub?.cancel();
      try {
        await session?.close().timeout(const Duration(seconds: 3));
      } on Object catch (e) {
        debugPrint('background check: close failed: $e');
      }
    }
    return complete;
  }

  Duration _cap(Duration d, int maxSeconds) {
    final max = Duration(seconds: maxSeconds);
    if (d <= Duration.zero) return const Duration(milliseconds: 1);
    return d < max ? d : max;
  }

  /// [f] bounded by [limit] (plus a second of grace for the callee's own
  /// timeout); errors are absorbed.
  Future<T> _bounded<T>(Future<T> f, T onError, Duration limit) async {
    try {
      return await f.timeout(limit + const Duration(seconds: 1));
    } on Object catch (e) {
      debugPrint('background check step failed: $e');
      return onError;
    }
  }
}
