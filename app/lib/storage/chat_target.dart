/// A conversation the chat screen can open: either an existing chat row
/// ([chatId] set) or a *draft* (no row yet). A draft becomes a chat only when
/// its first message is sent; opening it and leaving stores nothing.
class ChatTarget {
  const ChatTarget({
    this.chatId,
    required this.identity,
    required this.peer,
    this.name,
  });

  /// Row id of the existing chat, null for a draft.
  final int? chatId;

  /// `'A'` or `'B'`.
  final String identity;

  /// Peer LXMF address, lowercase hex.
  final String peer;

  /// Display name known when the conversation was opened (optional).
  final String? name;

  bool get isDraft => chatId == null;

  /// Key for the in-memory (session only) unsent composer text.
  String get draftKey => '$identity:$peer';
}
