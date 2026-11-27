import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/bridge/codec.dart';
import 'package:kestrel/bridge/vault_service.dart';
import 'package:kestrel/node/identity_store.dart';
import 'package:kestrel/nomadnet/browser_sync.dart';
import 'package:kestrel/nomadnet/nomad_store.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_bridge_api.dart';

const n1 = '11111111111111111111111111111111';
const n2 = '22222222222222222222222222222222';
const url1 = '$n1:/page/index.mu';

/// The vault part of the bridge, shared by several devices (see
/// vault_service_test.dart for the single-device model it is cut from).
class SharedVault {
  final devices = <String, Map<String, Object?>>{};
  final apis = <String, FakeBridgeApi>{};
  bool inUse = false;
  final wrapped = <String, Uint8List>{};
  final blobs = <Map<String, Object?>>[];
  final lastSeq = <String, int>{};

  void add(String id, Identity i, FakeBridgeApi api) {
    devices[id] = {
      ...deviceMap(id),
      'public_key': toHex(i.publicKey),
      'revoked_at': null,
    };
    apis[id] = api;
    api.handlers['/devices/list'] = (a) => {
      'devices': devices.values.toList(),
      'key_epoch': 1,
    };
    api.handlers['/vault/key'] = (a) => {
      'key_epoch': 1,
      'in_use': inUse,
      'wrapped_epoch': wrapped.containsKey(id) ? 1 : null,
      'wrapped_group_key': wrapped[id],
      'wrap': wrapped.containsKey(id) ? 'identity' : null,
    };
    api.handlers['/vault/set_keys'] = (a) {
      if (inUse) throw BridgeError('keys_already_set', '', {'key_epoch': 1});
      wrapped.addAll(
        (a['wrapped_group_keys']! as Map).cast<String, Uint8List>(),
      );
      inUse = true;
      return {'key_epoch': 1};
    };
    api.handlers['/vault/put'] = (a) {
      final dev = a['device_id']! as String;
      final last = lastSeq[dev] ?? 0;
      if (a['seq'] != last + 1) {
        throw BridgeError('seq_conflict', '', {'last_seq': last});
      }
      lastSeq[dev] = last + 1;
      final ct = a['ciphertext']! as Uint8List;
      blobs.add({
        'vcursor': blobs.length + 1,
        'blob_id': a['blob_id'],
        'device_id': dev,
        'seq': a['seq'],
        'key_epoch': a['key_epoch'],
        'size': ct.length,
        'ciphertext': ct,
      });
      return {'blob_id': a['blob_id'], 'duplicate': false};
    };
    api.handlers['/vault/list'] = (a) {
      final cur = a['cursor']! as int;
      final rows = blobs.where((b) => (b['vcursor']! as int) > cur).toList();
      final page = rows.take(a['limit']! as int).toList();
      return {
        'blobs': [
          for (final b in page) {...b}..remove('ciphertext'),
        ],
        'cursor': page.isEmpty ? cur : page.last['vcursor'],
        'more': rows.length > page.length,
        'key_epoch': 1,
      };
    };
    api.handlers['/vault/get'] = (a) => {
      'blobs': [
        for (final id in (a['blob_ids']! as List).cast<String>())
          ...blobs.where((b) => b['blob_id'] == id),
      ],
      'missing': <String>[],
      'truncated': <String>[],
    };
  }
}

class Device {
  Device(this.id, this.adb, this.api, this.vault)
    : repo = Repo(adb),
      nomad = NomadStore(adb);
  final String id;
  final AppDatabase adb;
  final FakeBridgeApi api;
  final Repo repo;
  final NomadStore nomad;
  final VaultService vault;
}

void main() {
  setUpAll(sqfliteFfiInit);

  group('merge rules', () {
    late AppDatabase adb;
    late NomadStore s;
    late BrowserSyncStore b;

    setUp(() async {
      adb = await AppDatabase.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      s = NomadStore(adb);
      b = BrowserSyncStore(adb);
    });
    tearDown(() => adb.close());

    Map<String, Object?> put(int ts, [String title = 't']) =>
        BrowserOps.bookmarkPut(url1, '$title$ts', ts, ts);
    Map<String, Object?> del(int ts) => BrowserOps.bookmarkDel(url1, ts);

    test('last writer wins per key, whatever the arrival order', () async {
      expect(await b.apply([put(10), put(30), put(20)]), 2);
      expect((await s.bookmarks()).single.title, 't30');
    });

    test('a tombstone beats an older put', () async {
      await b.apply([del(20)]);
      expect(await b.apply([put(10)]), 0);
      expect(await s.bookmarks(), isEmpty);
    });

    test('a newer put after a delete restores the item', () async {
      await b.apply([put(10), del(20)]);
      expect(await s.bookmarks(), isEmpty);
      await b.apply([put(30)]);
      expect((await s.bookmarks()).single.title, 't30');
    });

    test('every arrival order of put/delete/put converges', () async {
      final ops = [put(10), del(20), put(30), del(25)];
      final perms = <List<int>>[
        [0, 1, 2, 3],
        [3, 2, 1, 0],
        [2, 0, 3, 1],
        [1, 3, 0, 2],
      ];
      for (final p in perms) {
        await adb.db.delete('browser_sync');
        await adb.db.delete('nomad_bookmarks');
        await b.apply([for (final i in p) ops[i]]);
        expect((await s.bookmarks()).single.title, 't30', reason: '$p');
      }
    });

    test('equal timestamps: the tombstone wins, on both orders', () async {
      await b.apply([put(10), del(10)]);
      expect(await s.bookmarks(), isEmpty);
      await adb.db.delete('browser_sync');
      await b.apply([del(10), put(10)]);
      expect(await s.bookmarks(), isEmpty);
    });

    test('a local edit beats a remote record from a faster clock', () async {
      await b.apply([put(5000000000000)]);
      await s.removeBookmark(url1);
      expect(await s.bookmarks(), isEmpty);
      final ops = await b.pending(limit: 10);
      expect(ops.single.op['op'], 'bookmark.del');
      expect(ops.single.op['ts'], 5000000000001);
    });

    test('favourites and settings merge per key', () async {
      await b.apply([
        BrowserOps.favPut(n1, 'Node', 10),
        BrowserOps.settingPut(n1, 'font_scale', 1.5, 10),
        BrowserOps.settingPut(n1, 'wrap_all', true, 10),
        BrowserOps.settingPut(n1, 'wrap_all', false, 5),
        BrowserOps.settingPut(n1, 'identify', true, 10),
      ]);
      var n = (await s.node(n1))!;
      expect(
        [n.favourite, n.name, n.fontScale, n.wrapAll, n.identify],
        [true, 'Node', 1.5, true, true],
      );
      await b.apply([
        BrowserOps.favDel(n1, 20),
        BrowserOps.favPut(n1, 'Node', 15),
      ]);
      n = (await s.node(n1))!;
      expect(n.favourite, isFalse);
      expect(n.fontScale, 1.5);
    });

    test(
      'local edits are queued and marked sent only when unchanged',
      () async {
        await s.addBookmark(url1, 'A', nowMs: 100);
        await s.setFavourite(n1, true);
        await s.setViewPrefs(n1, fontScale: 1.25, wrapAll: true);
        await s.setIdentify(n1, true);
        final ops = await b.pending(limit: 50);
        expect(ops.map((o) => o.op['op']).toSet(), {
          'bookmark.put',
          'fav.put',
          'node_settings.put',
        });
        expect(ops.length, 5);
        // edited again while "uploading": stays dirty
        await s.removeBookmark(url1);
        await adb.db.transaction(
          (t) =>
              BrowserSyncStore.completeMarks(t, [for (final o in ops) o.mark]),
        );
        final left = await b.pending(limit: 50);
        expect(left.single.op['op'], 'bookmark.del');
      },
    );

    test('unknown and malformed ops are skipped', () async {
      expect(
        await b.apply([
          {'op': 'future.thing', 'ts': 1},
          'junk',
          {'op': 'bookmark.put', 'url': '', 'title': 'x', 'ts': 1},
          {
            'op': 'node_settings.put',
            'node': n1,
            'key': 'bogus',
            'value': 1,
            'ts': 1,
          },
          {
            'op': 'node_settings.put',
            'node': n1,
            'key': 'font_scale',
            'value': 'x',
            'ts': 1,
          },
          put(7),
        ]),
        1,
      );
    });

    test('history is capped at 500, locally and from remote', () async {
      for (var i = 0; i < 520; i++) {
        await s.addHistory('$n1:/p$i', 'p$i', nowMs: 1000 + i);
      }
      var h = await s.history(limit: 1000);
      expect(h.length, 500);
      expect(h.first.url, '$n1:/p519');
      expect(h.last.url, '$n1:/p20');
      await b.apply([
        for (var i = 0; i < 100; i++)
          BrowserOps.historyAdd('$n2:/r$i', 'r', 5000 + i),
        BrowserOps.historyAdd('$n2:/old', 'old', 1),
      ]);
      h = await s.history(limit: 1000);
      expect(h.length, 500);
      expect(h.first.url, '$n2:/r99');
      expect(h.any((e) => e.url == '$n2:/old'), isFalse);
    });

    test('history.add is idempotent', () async {
      final op = BrowserOps.historyAdd(url1, 't', 100);
      expect(await b.apply([op, op]), 1);
      expect(await b.apply([op]), 0);
      expect((await s.history()).length, 1);
    });

    test(
      'history.clear is a watermark: older visits go, later ones stay',
      () async {
        await b.apply([
          BrowserOps.historyAdd('$n1:/a', 'a', 10),
          BrowserOps.historyAdd('$n1:/b', 'b', 60),
        ]);
        await b.apply([BrowserOps.historyClear(50)]);
        expect((await s.history()).map((e) => e.url), ['$n1:/b']);
        // an old visit that arrives late is refused; a newer one is kept
        await b.apply([
          BrowserOps.historyAdd('$n1:/late', 'l', 40),
          BrowserOps.historyAdd('$n1:/new', 'n', 70),
          BrowserOps.historyClear(20), // older clear: no effect
        ]);
        expect((await s.history()).map((e) => e.url), ['$n1:/new', '$n1:/b']);
      },
    );

    test('a local clear is queued and clears unsent visits', () async {
      await s.addHistory(url1, 't', nowMs: 10);
      await s.clearHistory();
      final ops = await b.pending(limit: 10, historyMinAgeMs: 0);
      expect(ops.single.op['op'], 'history.clear');
    });

    test(
      'history is batched: not pending until the oldest visit is due',
      () async {
        await s.addHistory(url1, 't', nowMs: 1000);
        expect(await b.pending(limit: 10), isEmpty);
        expect(
          await b.pending(limit: 10, historyMinAgeMs: 180000, nowMs: 2000),
          isEmpty,
        );
        expect(
          (await b.pending(
            limit: 10,
            historyMinAgeMs: 180000,
            nowMs: 200000,
          )).single.op['op'],
          'history.add',
        );
        expect(
          (await b.pending(limit: 10, historyMinAgeMs: 0, nowMs: 1001)).length,
          1,
        );
      },
    );

    test('backfill imports existing data once, and never replaces newer records', () async {
      final d = adb.db;
      await d.insert('nomad_bookmarks', {
        'url': url1,
        'title': 'old',
        'created': 100,
      });
      await d.insert('nomad_bookmarks', {
        'url': 'x:/y',
        'title': 'y',
        'created': 200,
      });
      await d.insert('nomad_nodes', {
        'hash': n1,
        'name': 'N',
        'first_seen': 50,
        'last_seen': 60,
        'favourite': 1,
        'identify': 1,
        'font_scale': 2.0,
      });
      await d.insert('nomad_nodes', {
        'hash': n2,
        'first_seen': 1,
        'last_seen': 1,
      });
      // a remote deletion that is newer than the import wins over the local row
      final store = <String, String>{};
      await b.apply([BrowserOps.bookmarkDel('x:/y', 500)]);
      await b.backfillOnce((k) async => store[k], (k, v) async => store[k] = v);
      final ops = await b.pending(limit: 50);
      expect(ops.map((o) => o.op['op']).toList()..sort(), [
        'bookmark.put',
        'fav.put',
        'node_settings.put',
        'node_settings.put',
      ]);
      expect(store[SettingKeys.browserBackfilled], '1');
      // second run: nothing to do (even if a setting row is removed again)
      await d.delete('browser_sync');
      await b.backfillOnce((k) async => store[k], (k, v) async => store[k] = v);
      expect(await b.pending(limit: 50), isEmpty);
    });
  });

  group('two devices through the shared vault', () {
    late SharedVault server;
    late Device d1;
    late Device d2;
    final id1 = '0a' * 16;
    final id2 = '0b' * 16;

    Future<Device> make(
      String id, {
      Duration historyBatch = const Duration(minutes: 3),
    }) async {
      // a file per device: sqflite would share one in-memory instance
      final dir = Directory.systemTemp.createTempSync('kestrel_bs');
      final adb = await AppDatabase.open(
        '${dir.path}/$id.db',
        factory: databaseFactoryFfi,
      );
      final api = FakeBridgeApi(vaultStubs: false);
      final identity = await Identity.generate();
      server.add(id, identity, api);
      final v = VaultService(
        repo: Repo(adb),
        keys: VaultKeys(MemorySecretStore()),
        identity: () => identity,
        ownDeviceId: () => id,
        historyBatch: historyBatch,
      );
      await v.attach(api, 'cd' * 64);
      return Device(id, adb, api, v);
    }

    Future<void> sync(
      Device d, {
      Map<String, Object?> limits = const {},
    }) async {
      d.api.up = true;
      await d.vault.onConnected(
        helloFor(d.id, vaultInUse: server.inUse, limits: limits),
      );
      await d.vault.whenIdle();
    }

    Future<void> both() async {
      await sync(d1);
      await sync(d2);
      await sync(d1);
    }

    setUp(() async {
      server = SharedVault();
      d1 = await make(id1);
      d2 = await make(id2);
      // register both before the first activation wraps keys for everybody
    });
    tearDown(() async {
      await d1.vault.detach();
      await d2.vault.detach();
      await d1.adb.close();
      await d2.adb.close();
    });

    test(
      'bookmark, favourite and settings round trip; deletion propagates',
      () async {
        await sync(d1);
        await sync(d2);
        await d1.nomad.addBookmark(url1, 'Home');
        await d1.nomad.setFavourite(n1, true);
        await d1.nomad.setViewPrefs(n1, fontScale: 1.5, wrapAll: true);
        await both();
        expect((await d2.nomad.bookmarks()).single.title, 'Home');
        var n = (await d2.nomad.node(n1))!;
        expect([n.favourite, n.fontScale, n.wrapAll], [true, 1.5, true]);
        // a setting change propagates
        await d1.nomad.setViewPrefs(n1, fontScale: 2.0);
        await both();
        expect((await d2.nomad.node(n1))!.fontScale, 2.0);
        // deleted on device 2 disappears on device 1
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await d2.nomad.removeBookmark(url1);
        await d2.nomad.setFavourite(n1, false);
        await sync(d2);
        await sync(d1);
        expect(await d1.nomad.bookmarks(), isEmpty);
        expect((await d1.nomad.node(n1))!.favourite, isFalse);
        // and a later re-add on device 1 restores it everywhere
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await d1.nomad.addBookmark(url1, 'Back');
        await sync(d1);
        await sync(d2);
        expect((await d2.nomad.bookmarks()).single.title, 'Back');
        final (sent, _) = await d1.vault.store.browserCounts();
        final (_, got) = await d2.vault.store.browserCounts();
        expect(sent, greaterThan(0));
        expect(got, greaterThan(0));
        expect((await d2.vault.snapshot()).browserReceived, got);
      },
    );

    test(
      'existing data is backfilled on first sync and reaches the other device',
      () async {
        // data from before this version: no records were written
        await d1.adb.db.insert('nomad_bookmarks', {
          'url': url1,
          'title': 'Old',
          'created': 100,
        });
        await d1.adb.db.insert('nomad_nodes', {
          'hash': n1,
          'first_seen': 1,
          'last_seen': 1,
          'favourite': 1,
          'wrap_all': 1,
        });
        await d1.adb.db.insert('nomad_history', {
          'url': url1,
          'title': 'h',
          'ts': 5,
        });
        await sync(d1);
        await d1.vault.flushHistory();
        await d1.vault.whenIdle();
        await sync(d2);
        expect((await d2.nomad.bookmarks()).single.title, 'Old');
        final n = (await d2.nomad.node(n1))!;
        expect([n.favourite, n.wrapAll], [true, true]);
        expect((await d2.nomad.history()).single.url, url1);
      },
    );

    test('history is uploaded in batches, at once when flushed', () async {
      await sync(d1);
      final before = server.blobs.length;
      await d1.nomad.addHistory(url1, 'a');
      await d1.nomad.addHistory('$n2:/x', 'b');
      await sync(d1);
      expect(server.blobs.length, before, reason: 'not due yet');
      await d1.vault.flushHistory();
      await d1.vault.whenIdle();
      expect(server.blobs.length, before + 1, reason: 'one batch, one blob');
      await sync(d2);
      expect((await d2.nomad.history()).length, 2);
      // nothing left to send
      await d1.vault.flushHistory();
      await d1.vault.whenIdle();
      expect(server.blobs.length, before + 1);
    });

    test('history becomes due by itself after the batch interval', () async {
      final d3 = await make(
        '0c' * 16,
        historyBatch: const Duration(milliseconds: 50),
      );
      addTearDown(() async {
        await d3.vault.detach();
        await d3.adb.close();
      });
      await sync(d3);
      final before = server.blobs.length;
      await d3.nomad.addHistory(url1, 'a');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await sync(d3);
      expect(server.blobs.length, before + 1);
    });

    test('many records are split into blobs under the size limit', () async {
      await sync(d1, limits: {'vault_max_blob_bytes': 4096});
      for (var i = 0; i < 150; i++) {
        await d1.nomad.addBookmark('$n1:/page/$i.mu', 'Bookmark number $i');
      }
      await sync(d1, limits: {'vault_max_blob_bytes': 4096});
      await sync(d2, limits: {'vault_max_blob_bytes': 4096});
      final mine = server.blobs.where((b) => b['device_id'] == id1).toList();
      expect(mine.length, greaterThan(2));
      expect(mine.every((b) => (b['size']! as int) <= 4096), isTrue);
      expect((await d2.nomad.bookmarks()).length, 150);
    });

    test(
      'a blob kind from a newer app is ignored, later blobs still apply',
      () async {
        await sync(d1);
        await sync(d2);
        final chain = d1.vault.keys.chain;
        Future<void> inject(
          int seq,
          String kind,
          Map<String, Object?> data,
        ) async {
          final dev = 'ee' * 16;
          final id = toHex(secureRandomBytes(16));
          final ct = await VaultCrypto.encryptBlob(
            groupKey: chain[1]!,
            blobId: id,
            deviceId: dev,
            seq: seq,
            keyEpoch: 1,
            kind: kind,
            ts: 1.0,
            data: data,
          );
          server.blobs.add({
            'vcursor': server.blobs.length + 1,
            'blob_id': id,
            'device_id': dev,
            'seq': seq,
            'key_epoch': 1,
            'size': ct.length,
            'ciphertext': ct,
          });
        }

        await inject(1, 'telepathy', {'x': 1});
        await inject(2, browserBlobKind, {
          'ops': [
            {'op': 'quantum.put', 'ts': 1},
            BrowserOps.bookmarkPut(url1, 'Fine', 9, 9),
          ],
        });
        await sync(d2);
        expect((await d2.vault.snapshot()).skippedBlobs, 0);
        expect((await d2.nomad.bookmarks()).single.title, 'Fine');
      },
    );

    test('bridge off: browser data stays local, remote data merged earlier stays', () async {
      await sync(d1);
      await sync(d2);
      await d1.nomad.addBookmark(url1, 'Home');
      await sync(d1);
      await sync(d2);
      await d2.vault.detach();
      await d2.repo.purgeBridgeAccountData();
      expect((await d2.nomad.bookmarks()).single.title, 'Home');
      // still works and still records edits for the next time the bridge is on
      await d2.nomad.addBookmark('x:/y', 'Mine');
      expect((await d2.nomad.bookmarks()).length, 2);
      expect(await d2.vault.store.hasUploadWork(), isTrue);
    });

    test('a recreated bridge database uploads everything again', () async {
      await sync(d1);
      await d1.nomad.addBookmark(url1, 'Home');
      await sync(d1);
      expect(await d1.vault.store.hasUploadWork(), isFalse);
      await d1.vault.store.resetForNewBridge();
      expect(await d1.vault.store.hasUploadWork(), isTrue);
    });
  });
}
