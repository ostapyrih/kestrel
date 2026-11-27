import 'notification_models.dart';

/// Why a message did or did not get a notification.
enum NotifyDecision { show, disabled, muted, focusedChat, duplicate, history }

/// Decides, per incoming message, whether to notify, and keeps the shown
/// notifications in step with the read state.
///
/// Pure logic over [NotificationSink], [AppFocus] and the prefs callback, so
/// the same code runs in the app, in the iOS background task and in tests.
class NotificationCoordinator {
  NotificationCoordinator({
    required this.sink,
    required this.prefs,
    required this.focus,
    required this.text,
    this.onFocusedMessage,
    this.seenLimit = 1000,
  });

  final NotificationSink sink;
  final Future<NotificationPrefs> Function() prefs;
  final AppFocus focus;
  final NotificationText Function() text;

  /// Called for a message of the chat the user is looking at (the caller
  /// marks it read: the chat screen only does that when it opens).
  final Future<void> Function(int chatId)? onFocusedMessage;

  final int seenLimit;
  final _seen = <String>{};

  /// Notified chats and how many messages each notification stands for.
  final _shown = <int, int>{};

  /// Last known unread count per chat (a drop to 0 means "read").
  final _unread = <int, int>{};

  /// Chats with a notification on screen.
  Set<int> get shownChats => _shown.keys.toSet();

  /// True if [hash] was seen before; remembers it.
  bool _duplicate(String hash) {
    if (!_seen.add(hash)) return true;
    if (_seen.length > seenLimit) _seen.remove(_seen.first);
    return false;
  }

  Future<NotifyDecision> onIncoming(IncomingMessage m) async {
    // the hash identifies the message, whichever route it took
    if (_duplicate(m.hash)) return NotifyDecision.duplicate;
    if (m.isHistory) return NotifyDecision.history;
    final p = await prefs();
    if (!p.enabled) return NotifyDecision.disabled;
    if (p.isMuted(m.identity, m.peerHash)) return NotifyDecision.muted;
    if (focus.appActive && focus.openChatId == m.chatId) {
      await onFocusedMessage?.call(m.chatId);
      return NotifyDecision.focusedChat;
    }
    final n = (_shown[m.chatId] ?? 0) + 1;
    _shown[m.chatId] = n;
    final t = text();
    final String title;
    final String body;
    if (p.showContent) {
      title = n > 1 ? '${m.sender} ($n)' : m.sender;
      body = preview(m.text);
    } else {
      title = t.appName;
      body = n > 1 ? t.newMessages(n) : t.newMessage;
    }
    await sink.show(
      NotificationRequest(
        chatId: m.chatId,
        title: title,
        body: body,
        sound: p.sound,
        count: n,
      ),
    );
    return NotifyDecision.show;
  }

  /// Latest unread counts of every chat. A chat that went from unread to read
  /// (here or on another device) or vanished loses its notification.
  Future<void> onUnread(Map<int, int> unreadByChat) async {
    final gone = <int>[];
    for (final c in _shown.keys) {
      final was = _unread[c] ?? 0;
      final now = unreadByChat[c];
      if (now == null || (was > 0 && now == 0)) gone.add(c);
    }
    _unread
      ..clear()
      ..addAll(unreadByChat);
    for (final c in gone) {
      await _clear(c);
    }
  }

  /// The user opened [chatId].
  Future<void> onChatOpened(int chatId) => _clear(chatId);

  /// Settings changed: nothing stays on screen that would not be shown now.
  /// [muted] maps the chats with a notification to their mute key.
  Future<void> onPrefsChanged(
    NotificationPrefs p, {
    Map<int, String> muteKeyOfChat = const {},
  }) async {
    if (!p.enabled) {
      _shown.clear();
      await sink.cancelAll();
      return;
    }
    for (final c in _shown.keys.toList()) {
      final k = muteKeyOfChat[c];
      if (k != null && p.mutedChats.contains(k)) await _clear(c);
    }
  }

  Future<void> _clear(int chatId) async {
    if (_shown.remove(chatId) == null) return;
    await sink.cancelChat(chatId);
  }

  /// One line of [text]: whitespace folded, cut to [max] characters.
  static String preview(String text, {int max = 140}) {
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (one.length <= max) return one;
    return '${one.substring(0, max - 1).trimRight()}…';
  }
}
