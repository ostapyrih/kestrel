/// Platform independent types of the notification feature. Nothing here
/// touches a plugin, so everything built on it is unit-testable.
library;

/// One message that just arrived and may deserve a notification.
class IncomingMessage {
  const IncomingMessage({
    required this.identity,
    required this.chatId,
    required this.peerHash,
    required this.sender,
    required this.text,
    required this.hash,
    required this.ts,
    this.isHistory = false,
  });

  /// `A` (bridge) or `B` (this device).
  final String identity;
  final int chatId;
  final String? peerHash;

  /// Display name of the sender (the chat title).
  final String sender;
  final String text;

  /// LXMF hash: the same message arriving directly, through a propagation
  /// node or through the bridge has the same hash.
  final String hash;
  final DateTime ts;

  /// A message that a history sync brought in (old, probably already read):
  /// never worth a notification.
  final bool isHistory;
}

/// The user's notification settings.
class NotificationPrefs {
  const NotificationPrefs({
    this.enabled = true,
    this.showContent = true,
    this.sound = true,
    this.mutedChats = const {},
  });

  final bool enabled;

  /// Show the sender and the text; off = a bare "New message".
  final bool showContent;
  final bool sound;

  /// [muteKey]s of the muted chats.
  final Set<String> mutedChats;

  bool isMuted(String identity, String? peerHash) =>
      mutedChats.contains(muteKey(identity, peerHash));
}

/// Mutes follow the conversation, not the local row id (which does not
/// survive deleting and recreating a chat).
String muteKey(String identity, String? peerHash) => '$identity:$peerHash';

/// What is on screen right now.
abstract class AppFocus {
  /// The app is in the foreground and its window has the focus.
  bool get appActive;

  /// The chat the user is looking at (null = none).
  int? get openChatId;
}

/// What the user gets to see.
class NotificationRequest {
  const NotificationRequest({
    required this.chatId,
    required this.title,
    required this.body,
    required this.sound,
    required this.count,
  });

  /// One notification per chat: showing again replaces it.
  final int chatId;
  final String title;
  final String body;
  final bool sound;

  /// Messages of this chat the notification stands for.
  final int count;

  String get payload => notificationPayload(chatId);
}

/// What a notification carries so that a tap opens its chat.
String notificationPayload(int chatId) => 'chat:$chatId';

/// The chat a payload names (null if it is not one of ours).
int? chatIdOfPayload(String? payload) {
  if (payload == null || !payload.startsWith('chat:')) return null;
  return int.tryParse(payload.substring(5));
}

/// The place notifications go to (a plugin; faked in tests).
abstract class NotificationSink {
  Future<void> show(NotificationRequest r);
  Future<void> cancelChat(int chatId);
  Future<void> cancelAll();
}

/// Words of a notification (a [NotificationSink] has no BuildContext).
class NotificationText {
  const NotificationText({
    required this.appName,
    required this.newMessage,
    required this.newMessages,
  });

  final String appName;
  final String newMessage;
  final String Function(int n) newMessages;
}
