import 'dart:async';

import 'package:flutter/widgets.dart';

import '../storage/repo.dart';
import 'notification_coordinator.dart';
import 'notification_models.dart';
import 'notification_prefs_store.dart';
import 'notification_strings.dart';

/// [AppFocus] from the app lifecycle and the chat screens.
///
/// On desktop the lifecycle goes `inactive` when the window loses focus and
/// `hidden` when it is hidden in the tray, so "not resumed" covers both.
class ChatFocus with WidgetsBindingObserver implements AppFocus {
  ChatFocus({this.onChatOpened});

  /// Called when a chat screen opens.
  final void Function(int chatId)? onChatOpened;

  bool _active = true;
  final _open = <int>[];

  void attach() => WidgetsBinding.instance.addObserver(this);
  void detach() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
  }

  @override
  bool get appActive => _active;

  @override
  int? get openChatId => _open.isEmpty ? null : _open.last;

  /// A chat screen showed [chatId].
  void opened(int chatId) {
    _open.add(chatId);
    onChatOpened?.call(chatId);
  }

  /// The chat screen of [chatId] went away.
  void closed(int chatId) => _open.remove(chatId);
}

/// Wires the database to the [NotificationCoordinator] while the app runs:
/// new incoming messages, read-state changes and settings changes.
class NotificationRuntime {
  NotificationRuntime({
    required this.repo,
    required this.sink,
    required this.focus,
    required this.lang,
    required this.markRead,
  }) {
    store = NotificationPrefsStore(repo);
    coordinator = NotificationCoordinator(
      sink: sink,
      prefs: store.load,
      focus: focus,
      text: () => notificationTextFor(lang()),
      onFocusedMessage: markRead,
    );
  }

  final Repo repo;
  final NotificationSink sink;
  final AppFocus focus;
  final String Function() lang;

  /// Marks the chat the user is looking at as read.
  final Future<void> Function(int chatId) markRead;

  late final NotificationPrefsStore store;
  late final NotificationCoordinator coordinator;
  final _subs = <StreamSubscription<Object?>>[];

  void start() {
    _subs
      ..add(
        repo.incomingMessages.listen(
          (m) => unawaited(coordinator.onIncoming(m).then((_) {})),
        ),
      )
      ..add(
        repo
            .watch(() async {
              final chats = await repo.chats();
              return {for (final c in chats) c.id: c.unread};
            })
            .listen((u) => unawaited(coordinator.onUnread(u))),
      )
      ..add(
        repo.watch(store.load).listen((p) async {
          final keys = <int, String>{};
          for (final c in await repo.chats()) {
            keys[c.id] = muteKey(c.accountIdentity, c.peerHash);
          }
          await coordinator.onPrefsChanged(p, muteKeyOfChat: keys);
        }),
      );
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}
