import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/nomadnet/browser_controller.dart';
import 'package:kestrel/nomadnet/nomad_store.dart';
import 'package:kestrel/nomadnet/page_cache.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/nomad_fakes.dart';

const hash = '0123456789abcdef0123456789abcdef';

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase adb;
  late NomadStore store;
  late List<FakeFetch> requests;
  late BrowserController c;
  late FakeSaver saver;
  late DateTime now;

  setUp(() async {
    adb = await AppDatabase.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    store = NomadStore(adb);
    requests = [];
    saver = FakeSaver();
    now = DateTime(2026, 1, 1, 12);
    c = BrowserController(
      fetch: (h, path, {data, identify = false}) {
        final f = FakeFetch(path, data, identify);
        requests.add(f);
        return f;
      },
      store: store,
      cache: PageCache(store, now: () => now),
      saver: saver,
    );
  });
  tearDown(() async {
    c.dispose();
    await adb.close();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  Future<void> load(String url, String markup) async {
    final f = c.open(url);
    await settle();
    requests.last.respond(markup);
    await f;
    await settle();
  }

  test('open: loading state, then the page is parsed and shown', () async {
    final f = c.open('$hash:/page/a.mu');
    await settle();
    expect(c.phase, BrowserPhase.loading);
    expect(requests.single.path, '/page/a.mu');
    expect(requests.single.data, isNull);
    requests.single.respond('>Title\nbody');
    await f;
    await settle();
    expect(c.phase, BrowserPhase.loaded);
    expect(c.title, 'Title');
    expect(c.document!.blocks.length, 2);
    expect(c.current!.text, '$hash:/page/a.mu');
    expect(c.lastHops, 2);
  });

  test('a bare hash opens the default page', () async {
    await load(hash, 'x');
    expect(requests.single.path, '/page/index.mu');
  });

  test('malformed addresses fail without a request', () async {
    expect(await c.open('nonsense'), isFalse);
    expect(c.phase, BrowserPhase.failed);
    expect(c.failureText, 'malformed');
    expect(requests, isEmpty);
  });

  test('link variables go out as var_*; field data merges in', () async {
    await load('$hash:/page/index.mu', 'x');
    unawaited(c.followLink(':/page/form.mu`a=1', {'field_name': 'bob'}));
    await settle();
    expect(requests.last.path, '/page/form.mu');
    expect(requests.last.data, {'var_a': '1', 'field_name': 'bob'});
  });

  test('same-node relative links resolve against the current node', () async {
    await load('$hash:/page/index.mu', 'x');
    unawaited(c.followLink(':/page/other.mu', null));
    await settle();
    expect(requests.last.path, '/page/other.mu');
    expect(c.target!.hashHex, hash);
  });

  test('back/forward keep the history and reload from the cache', () async {
    await load('$hash:/page/a.mu', '>A');
    unawaited(c.followLink(':/page/b.mu', null));
    await settle();
    requests.last.respond('>B');
    await settle();
    expect(c.title, 'B');
    expect(c.canGoBack, isTrue);
    expect(c.canGoForward, isFalse);
    final before = requests.length;
    await c.back();
    await settle();
    expect(c.title, 'A');
    expect(c.fromCache, isTrue);
    expect(requests.length, before, reason: 'served from the cache');
    expect(c.canGoForward, isTrue);
    await c.forward();
    await settle();
    expect(c.title, 'B');
    expect(requests.length, before);
  });

  test('navigating after back clears the forward stack', () async {
    await load('$hash:/page/a.mu', '>A');
    unawaited(c.followLink(':/page/b.mu', null));
    await settle();
    requests.last.respond('>B');
    await settle();
    await c.back();
    await settle();
    unawaited(c.followLink(':/page/c.mu', null));
    await settle();
    requests.last.respond('>C');
    await settle();
    expect(c.canGoForward, isFalse);
  });

  group('cache semantics', () {
    test('default 12 h; expires afterwards', () async {
      await load('$hash:/page/a.mu', 'plain');
      expect(requests.length, 1);
      unawaited(c.go(NomadUrl.parse('$hash:/page/a.mu')));
      await settle();
      expect(requests.length, 1);
      expect(c.fromCache, isTrue);
      now = now.add(const Duration(hours: 13));
      unawaited(c.go(NomadUrl.parse('$hash:/page/a.mu')));
      await settle();
      expect(requests.length, 2, reason: 'expired entry is refetched');
      requests.last.respond('plain2');
      await settle();
      expect(c.fromCache, isFalse);
    });

    test('#!c=0 is never cached, #!c=60 for a minute', () async {
      await load('$hash:/page/z.mu', '#!c=0\nzero');
      unawaited(c.go(NomadUrl.parse('$hash:/page/z.mu')));
      await settle();
      expect(requests.length, 2);
      requests.last.respond('#!c=0\nzero');
      await settle();

      await load('$hash:/page/m.mu', '#!c=60\nminute');
      final n = requests.length;
      unawaited(c.go(NomadUrl.parse('$hash:/page/m.mu')));
      await settle();
      expect(requests.length, n);
      now = now.add(const Duration(seconds: 61));
      unawaited(c.go(NomadUrl.parse('$hash:/page/m.mu')));
      await settle();
      expect(requests.length, n + 1);
    });

    test('requests with data bypass the cache', () async {
      await load('$hash:/page/f.mu', 'form');
      unawaited(
        c.go(NomadUrl.parse('$hash:/page/f.mu'), data: {'field_a': 'b'}),
      );
      await settle();
      expect(requests.length, 2);
      expect(requests.last.data, {'field_a': 'b'});
    });

    test('reload drops the cache entry and refetches', () async {
      await load('$hash:/page/a.mu', '>old');
      unawaited(c.reload());
      await settle();
      expect(requests.length, 2);
      requests.last.respond('>new');
      await settle();
      expect(c.title, 'new');
    });
  });

  test('failures keep the previous page and can be retried', () async {
    await load('$hash:/page/a.mu', '>A');
    final f = c.go(NomadUrl.parse('$hash:/page/b.mu'));
    await settle();
    requests.last.fail(NomadFailure.timeout);
    await f;
    await settle();
    expect(c.phase, BrowserPhase.failed);
    expect(c.failure, NomadFailure.timeout);
    expect(c.title, 'A');
    expect(c.target!.path, '/page/b.mu');
  });

  test(
    'cancel aborts the request and restores the idle/loaded phase',
    () async {
      unawaited(c.open('$hash:/page/a.mu'));
      await settle();
      await c.cancel();
      expect(requests.single.cancelled, isTrue);
      expect(c.phase, BrowserPhase.idle);
      expect(c.failure, isNull);
    },
  );

  test('a newer navigation cancels the previous request', () async {
    unawaited(c.open('$hash:/page/a.mu'));
    await settle();
    unawaited(c.open('$hash:/page/b.mu'));
    await settle();
    expect(requests.first.cancelled, isTrue);
    requests.last.respond('>B');
    await settle();
    expect(c.title, 'B');
  });

  group('files', () {
    test('a file link downloads without leaving the page', () async {
      await load('$hash:/page/a.mu', '>A');
      unawaited(c.followLink(':/file/x.bin', null));
      await settle();
      expect(requests.last.path, '/file/x.bin');
      requests.last.respondFile('x.bin', [1, 2, 3]);
      await settle();
      expect(c.title, 'A');
      expect(c.phase, BrowserPhase.loaded);
      expect(c.download!.name, 'x.bin');
      expect(await c.saveDownload(), isTrue);
      expect(saver.saved.single.$1, 'x.bin');
      expect(c.download!.savedTo, '/downloads/x.bin');
    });

    test('a cancelled save dialog leaves the file pending', () async {
      await load('$hash:/page/a.mu', '>A');
      unawaited(c.followLink(':/file/x.bin', null));
      await settle();
      requests.last.respondFile('x.bin', [1]);
      await settle();
      saver.cancel = true;
      expect(await c.saveDownload(), isFalse);
      expect(c.download!.savedTo, isNull);
    });

    test('files are never served from the cache', () async {
      unawaited(c.go(NomadUrl.parse('$hash:/file/x.bin')));
      await settle();
      requests.last.respondFile('x.bin', [1]);
      await settle();
      unawaited(c.go(NomadUrl.parse('$hash:/file/x.bin')));
      await settle();
      expect(requests.length, 2);
    });
  });

  group('other link kinds', () {
    test('lxmf link calls the chat opener', () async {
      String? opened;
      c.onOpenChat = (h) => opened = h;
      unawaited(c.followLink('lxmf@$hash', null));
      expect(opened, hash);
      expect(requests, isEmpty);
    });

    test('unsupported links report a failure text', () async {
      unawaited(c.followLink('rrc://$hash/room', null));
      expect(c.failureText, startsWith('unsupported:'));
    });

    test('var_anchor in the URL schedules a scroll', () async {
      final f = c.open('$hash:/page/a.mu`anchor=sec');
      await settle();
      requests.last.respond('>A');
      await f;
      await settle();
      expect(c.pendingAnchor, 'sec');
    });
  });

  group('identify, bookmarks, history', () {
    test('identify is off by default and follows the per-node flag', () async {
      await load('$hash:/page/a.mu', 'x');
      expect(requests.last.identify, isFalse);
      await store.setIdentify(hash, true);
      unawaited(c.go(NomadUrl.parse('$hash:/page/b.mu')));
      await settle();
      expect(requests.last.identify, isTrue);
    });

    test('bookmark toggle persists the current URL and title', () async {
      await load('$hash:/page/a.mu', '>Home');
      expect(await c.isBookmarked(), isFalse);
      await c.toggleBookmark();
      expect(await c.isBookmarked(), isTrue);
      final b = (await store.bookmarks()).single;
      expect(b.url, '$hash:/page/a.mu');
      expect(b.title, 'Home');
      await c.toggleBookmark();
      expect(await store.bookmarks(), isEmpty);
    });

    test('visited pages land in the history', () async {
      await load('$hash:/page/a.mu', '>A');
      unawaited(c.followLink(':/page/b.mu', null));
      await settle();
      requests.last.respond('>B');
      await settle();
      final h = await store.history();
      expect(h.map((e) => e.title), ['B', 'A']);
    });
  });
}
