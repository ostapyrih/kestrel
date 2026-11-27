import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/notifications/notification_coordinator.dart';
import 'package:kestrel/notifications/notification_models.dart';
import 'package:kestrel/notifications/notification_prefs_store.dart';

class FakeSink implements NotificationSink {
  final shown = <NotificationRequest>[];
  final cancelled = <int>[];
  int cancelAllCalls = 0;

  @override
  Future<void> show(NotificationRequest r) async => shown.add(r);
  @override
  Future<void> cancelChat(int chatId) async => cancelled.add(chatId);
  @override
  Future<void> cancelAll() async => cancelAllCalls++;
}

class FakeFocus implements AppFocus {
  @override
  bool appActive = false;
  @override
  int? openChatId;
}

const _text = NotificationText(
  appName: 'Kestrel',
  newMessage: 'New message',
  newMessages: _many,
);
String _many(int n) => '$n new messages';

IncomingMessage msg({
  int chat = 1,
  String hash = 'h1',
  String text = 'hello',
  String identity = 'B',
  String peer = 'aa',
  bool history = false,
}) => IncomingMessage(
  identity: identity,
  chatId: chat,
  peerHash: peer,
  sender: 'Alice',
  text: text,
  hash: hash,
  ts: DateTime(2026, 1, 1),
  isHistory: history,
);

void main() {
  late FakeSink sink;
  late FakeFocus focus;
  late NotificationPrefs prefs;
  late List<int> markedRead;
  late NotificationCoordinator c;

  setUp(() {
    sink = FakeSink();
    focus = FakeFocus();
    prefs = const NotificationPrefs();
    markedRead = [];
    c = NotificationCoordinator(
      sink: sink,
      prefs: () async => prefs,
      focus: focus,
      text: () => _text,
      onFocusedMessage: (id) async => markedRead.add(id),
    );
  });

  test('a new message shows sender and text, tagged for its chat', () async {
    expect(await c.onIncoming(msg()), NotifyDecision.show);
    final r = sink.shown.single;
    expect(r.title, 'Alice');
    expect(r.body, 'hello');
    expect(r.payload, 'chat:1');
    expect(chatIdOfPayload(r.payload), 1);
    expect(chatIdOfPayload('other'), isNull);
  });

  test('disabled: nothing is shown', () async {
    prefs = const NotificationPrefs(enabled: false);
    expect(await c.onIncoming(msg()), NotifyDecision.disabled);
    expect(sink.shown, isEmpty);
  });

  test('muted chat is silent, other chats are not', () async {
    prefs = NotificationPrefs(mutedChats: {muteKey('B', 'aa')});
    expect(await c.onIncoming(msg()), NotifyDecision.muted);
    expect(
      await c.onIncoming(msg(chat: 2, hash: 'h2', peer: 'bb')),
      NotifyDecision.show,
    );
    // the same peer under the other account is a different conversation
    expect(
      await c.onIncoming(msg(chat: 3, hash: 'h3', identity: 'A')),
      NotifyDecision.show,
    );
    expect(sink.shown.map((r) => r.chatId), [2, 3]);
  });

  test('hidden content: no name, no text', () async {
    prefs = const NotificationPrefs(showContent: false);
    await c.onIncoming(msg(text: 'secret'));
    final r = sink.shown.single;
    expect(r.title, 'Kestrel');
    expect(r.body, 'New message');
    expect(r.body, isNot(contains('secret')));
    await c.onIncoming(msg(hash: 'h2', text: 'secret 2'));
    expect(sink.shown.last.body, '2 new messages');
    expect(sink.shown.last.title, 'Kestrel');
  });

  test('the chat that is open and focused gets no notification', () async {
    focus
      ..appActive = true
      ..openChatId = 1;
    expect(await c.onIncoming(msg()), NotifyDecision.focusedChat);
    expect(sink.shown, isEmpty);
    expect(markedRead, [1]);
    // another chat still notifies
    expect(await c.onIncoming(msg(chat: 2, hash: 'h2')), NotifyDecision.show);
  });

  test('an open chat in an unfocused window still notifies', () async {
    focus
      ..appActive = false
      ..openChatId = 1;
    expect(await c.onIncoming(msg()), NotifyDecision.show);
    expect(markedRead, isEmpty);
  });

  test('one notification per chat, counting up', () async {
    await c.onIncoming(msg(hash: 'a'));
    await c.onIncoming(msg(hash: 'b', text: 'second'));
    expect(sink.shown.map((r) => r.chatId), [1, 1]);
    expect(sink.shown.last.title, 'Alice (2)');
    expect(sink.shown.last.body, 'second');
    expect(sink.shown.last.count, 2);
  });

  test(
    'the same message by direct, propagated and bridge copies once',
    () async {
      expect(await c.onIncoming(msg(hash: 'same')), NotifyDecision.show);
      // propagation node copy, then a copy through the bridge (other account)
      expect(await c.onIncoming(msg(hash: 'same')), NotifyDecision.duplicate);
      expect(
        await c.onIncoming(msg(hash: 'same', identity: 'A', chat: 9)),
        NotifyDecision.duplicate,
      );
      expect(sink.shown, hasLength(1));
    },
  );

  test('history from a sync never notifies', () async {
    expect(await c.onIncoming(msg(history: true)), NotifyDecision.history);
    expect(sink.shown, isEmpty);
  });

  test('read elsewhere: the notification is withdrawn', () async {
    await c.onIncoming(msg());
    await c.onUnread({1: 1});
    expect(sink.cancelled, isEmpty);
    await c.onUnread({1: 0}); // read on another device (bridge) or here
    expect(sink.cancelled, [1]);
    expect(c.shownChats, isEmpty);
    // a later message notifies from a fresh count
    await c.onIncoming(msg(hash: 'n'));
    expect(sink.shown.last.title, 'Alice');
  });

  test('a snapshot that predates the unread flag does not cancel', () async {
    // account A: the message is announced before the chat is flagged unread
    await c.onIncoming(msg(identity: 'A'));
    await c.onUnread({1: 0});
    expect(sink.cancelled, isEmpty);
    await c.onUnread({1: 1});
    await c.onUnread({1: 0});
    expect(sink.cancelled, [1]);
  });

  test('a deleted chat loses its notification', () async {
    await c.onIncoming(msg());
    await c.onUnread({});
    expect(sink.cancelled, [1]);
  });

  test('opening the chat clears it; unknown chats are ignored', () async {
    await c.onIncoming(msg());
    await c.onChatOpened(5);
    expect(sink.cancelled, isEmpty);
    await c.onChatOpened(1);
    expect(sink.cancelled, [1]);
  });

  test('switching notifications off clears everything', () async {
    await c.onIncoming(msg());
    await c.onPrefsChanged(const NotificationPrefs(enabled: false));
    expect(sink.cancelAllCalls, 1);
    expect(c.shownChats, isEmpty);
  });

  test('muting a chat withdraws its notification', () async {
    await c.onIncoming(msg());
    await c.onPrefsChanged(
      NotificationPrefs(mutedChats: {muteKey('B', 'aa')}),
      muteKeyOfChat: {1: muteKey('B', 'aa')},
    );
    expect(sink.cancelled, [1]);
  });

  test('preview folds whitespace and cuts long text', () {
    expect(NotificationCoordinator.preview('a\n\n b\t c'), 'a b c');
    final long = 'x' * 300;
    final p = NotificationCoordinator.preview(long);
    expect(p.length, 140);
    expect(p.endsWith('…'), isTrue);
  });

  test('prefs store: defaults on, mutes round-trip', () {
    expect(NotificationPrefsStore.flag(null), isTrue);
    expect(NotificationPrefsStore.flag('0'), isFalse);
    expect(NotificationPrefsStore.parseMuted('B:aa\n\nA:bb\n'), {
      'B:aa',
      'A:bb',
    });
  });
}
