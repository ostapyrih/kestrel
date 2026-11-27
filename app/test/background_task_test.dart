import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/notifications/background_task.dart';
import 'package:kestrel/notifications/notification_prefs_store.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'notification_coordinator_test.dart' show FakeSink;

class FakeSession implements BackgroundSession {
  FakeSession(this.repo, {this.online = true, this.inbox, this.hang = false});

  @override
  final Repo repo;
  final bool online;
  final Future<void> Function(Repo repo)? inbox;
  final bool hang;
  final calls = <String>[];
  bool closed = false;

  @override
  Future<bool> connect(Duration timeout) async {
    calls.add('connect');
    if (hang) await Completer<void>().future;
    return online;
  }

  @override
  Future<void> syncInbox(Duration timeout) async {
    calls.add('inbox');
    await inbox?.call(repo);
  }

  @override
  Future<void> syncBridge(Duration timeout) async => calls.add('bridge');

  @override
  Future<void> close() async => closed = true;
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Repo repo;
  late FakeSink sink;

  setUp(() async {
    // a file per test: the in-memory database is shared between opens
    final dir = Directory.systemTemp.createTempSync('kestrel_bg_');
    final adb = await AppDatabase.open(
      '${dir.path}/t.db',
      factory: databaseFactoryFfi,
    );
    repo = Repo(adb);
    addTearDown(() async {
      try {
        await adb.close();
        dir.deleteSync(recursive: true);
      } on Object {
        // a temp dir may stay behind (Windows keeps files locked)
      }
    });
    sink = FakeSink();
  });

  Future<void> deliver(Repo r, String peer, String hash, String text) async {
    final chat = await r.findOrCreateChat('B', peer, title: 'Alice');
    await r.insertIncoming(
      identity: 'B',
      chatId: chat,
      lxmfHash: hash,
      text: text,
      ts: DateTime.now(),
      route: 'propagated',
      transport: 'tcp',
      signatureValid: true,
    );
  }

  BackgroundInboxCheck check(FakeSession s, {Duration? budget}) =>
      BackgroundInboxCheck(
        open: () async => s,
        sink: sink,
        lang: () => 'en',
        budget: budget ?? const Duration(seconds: 25),
      );

  test('runs the sync steps and posts a notification per new chat', () async {
    final s = FakeSession(
      repo,
      inbox: (r) async {
        await deliver(r, 'aa', 'h1', 'hi there');
        await deliver(r, 'bb', 'h2', 'second chat');
      },
    );
    final c = check(s);
    expect(await c.run(), isTrue);
    expect(s.calls, ['connect', 'inbox', 'bridge']);
    expect(s.closed, isTrue);
    expect(c.notified, 2);
    expect(
      sink.shown.map((r) => r.body),
      unorderedEquals(['hi there', 'second chat']),
    );
    expect(sink.shown.every((r) => r.title == 'Alice'), isTrue);
  });

  test('settings are honoured: hidden content, notifications off', () async {
    await NotificationPrefsStore(repo).setFlag(NotifKeys.content, false);
    final s = FakeSession(repo, inbox: (r) => deliver(r, 'aa', 'h1', 'secret'));
    await check(s).run();
    expect(sink.shown.single.body, 'New message');

    sink.shown.clear();
    await NotificationPrefsStore(repo).setFlag(NotifKeys.enabled, false);
    final s2 = FakeSession(repo, inbox: (r) => deliver(r, 'aa', 'h2', 'x'));
    await check(s2).run();
    expect(sink.shown, isEmpty);
    // the message is stored all the same
    expect(await repo.hasMessageHash('B', 'h2'), isTrue);
  });

  test('no connection: no sync, still shuts down, reports failure', () async {
    final s = FakeSession(repo, online: false);
    expect(await check(s).run(), isFalse);
    expect(s.calls, ['connect']);
    expect(s.closed, isTrue);
  });

  test('a failing sync does not stop shutdown or throw', () async {
    final s = FakeSession(
      repo,
      inbox: (r) async => throw StateError('node down'),
    );
    await check(s).run();
    expect(s.calls, contains('bridge'));
    expect(s.closed, isTrue);
  });

  test('a hanging connect is cut off by the time budget', () async {
    final s = FakeSession(repo, hang: true);
    final sw = Stopwatch()..start();
    final ok = await check(s, budget: const Duration(seconds: 6)).run();
    expect(ok, isFalse);
    expect(sw.elapsed, lessThan(const Duration(seconds: 9)));
    expect(s.closed, isTrue);
  });
}
