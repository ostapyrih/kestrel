import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/bridge/bridge_service.dart';
import 'package:kestrel/bridge/codec.dart';
import 'package:kestrel/bridge/vault_service.dart';
import 'package:kestrel/node/identity_store.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_bridge_api.dart';

final me = '0a' * 16;
final other = 'bb' * 16;
final peer = '11' * 16;

/// The parts of the bridge the vault touches, modelled after
/// bridge/kestrel_bridge/vault.py (strict seq, epochs, exact key coverage).
class VaultServer {
  VaultServer(this.api, this.devices);
  final FakeBridgeApi api;

  /// device id -> (record map, identity)
  final Map<String, (Map<String, Object?>, Identity)> devices;
  bool inUse = false;
  int epoch = 1;
  final wrapped = <String, Uint8List>{};
  final wrapKind = <String, String>{};
  final blobs = <Map<String, Object?>>[];
  final lastSeq = <String, int>{};
  int quota = 1 << 30;
  int maxGetBytes = 1 << 30;
  int putFailuresLeft = 0; // transport failure AFTER the blob is stored
  int staleOnce = 0;
  final putLog = <Map<String, Object?>>[];
  final approves = <Map<String, Object?>>[];
  final revokes = <Map<String, Object?>>[];
  int revokeStaleLeft = 0;

  Set<String> get trusted => {
    for (final e in devices.entries)
      if (e.value.$1['revoked_at'] == null) e.key,
  };

  void install() {
    api.handlers['/devices/list'] = (a) => {
      'devices': [for (final d in devices.values) d.$1],
      'key_epoch': epoch,
    };
    api.handlers['/vault/key'] = (a) => {
      'key_epoch': epoch,
      'in_use': inUse,
      'wrapped_epoch': wrapped.containsKey(me) ? epoch : null,
      'wrapped_group_key': wrapped[me],
      'wrap': wrapKind[me],
    };
    api.handlers['/vault/set_keys'] = (a) {
      if (inUse) {
        throw BridgeError('keys_already_set', '', {'key_epoch': epoch});
      }
      final w = a['wrapped_group_keys']! as Map;
      final ids = w.keys.cast<String>().toSet();
      if (ids.difference(trusted).isNotEmpty ||
          trusted.difference(ids).isNotEmpty) {
        throw BridgeError('bad_request', '', {
          'missing': trusted.difference(ids).toList(),
          'unexpected': ids.difference(trusted).toList(),
        });
      }
      for (final e in w.entries) {
        wrapped[e.key as String] = e.value as Uint8List;
        wrapKind[e.key as String] = 'identity';
      }
      inUse = true;
      return {'key_epoch': epoch};
    };
    api.handlers['/devices/invite'] = (a) => {
      'invite_id': 'ii' * 16,
      'token': Uint8List(16),
      'expires_at': 1700000600.0,
    };
    api.handlers['/devices/approve'] = (a) {
      approves.add(a);
      return {
        'device': {'device_id': 'cc' * 16},
      };
    };
    api.handlers['/devices/revoke'] = (a) {
      revokes.add(a);
      if (revokeStaleLeft > 0) {
        revokeStaleLeft--;
        epoch++; // somebody else revoked first
        throw BridgeError('key_epoch_stale', '', {'key_epoch': epoch});
      }
      final id = a['device_id']! as String;
      if (inUse) {
        if (a['key_epoch'] != epoch + 1) {
          throw BridgeError('key_epoch_stale', '', {'key_epoch': epoch});
        }
        final w = (a['wrapped_group_keys']! as Map).cast<String, Uint8List>();
        final remaining = trusted.difference({id});
        if (w.keys.toSet().difference(remaining).isNotEmpty ||
            remaining.difference(w.keys.toSet()).isNotEmpty) {
          throw BridgeError('bad_request');
        }
        wrapped
          ..clear()
          ..addAll(w);
        for (final k in w.keys) {
          wrapKind[k] = 'identity';
        }
      }
      epoch++;
      devices[id]!.$1['revoked_at'] = 5.0;
      return {'device': devices[id]!.$1, 'key_epoch': epoch};
    };
    api.handlers['/vault/put'] = (a) {
      if (staleOnce > 0) {
        staleOnce--;
        epoch++;
        throw BridgeError('key_epoch_stale', '', {'key_epoch': epoch});
      }
      putLog.add(a);
      final dev = a['device_id']! as String;
      final id = a['blob_id']! as String;
      final ct = a['ciphertext']! as Uint8List;
      final prev = blobs.where((b) => b['blob_id'] == id).toList();
      if (prev.isNotEmpty) {
        return {...prev.first, 'ciphertext': null, 'duplicate': true};
      }
      if (a['key_epoch'] != epoch) {
        throw BridgeError('key_epoch_stale', '', {'key_epoch': epoch});
      }
      final last = lastSeq[dev] ?? 0;
      if (a['seq'] != last + 1) {
        throw BridgeError('seq_conflict', '', {'last_seq': last});
      }
      final used = blobs
          .where((b) => b['device_id'] == dev)
          .fold<int>(0, (n, b) => n + (b['size']! as int));
      if (used + ct.length > quota) {
        throw BridgeError('quota_exceeded', '', {
          'scope': 'device',
          'used': used,
          'quota': quota,
        });
      }
      lastSeq[dev] = last + 1;
      blobs.add({
        'vcursor': blobs.length + 1,
        'blob_id': id,
        'device_id': dev,
        'seq': a['seq'],
        'key_epoch': a['key_epoch'],
        'size': ct.length,
        'ciphertext': ct,
      });
      if (putFailuresLeft > 0) {
        putFailuresLeft--;
        throw BridgeTransportError('lost response');
      }
      return {'blob_id': id, 'duplicate': false};
    };
    api.handlers['/vault/list'] = (a) {
      final cur = a['cursor']! as int;
      final rows = blobs.where((b) => (b['vcursor']! as int) > cur).toList();
      final lim = a['limit']! as int;
      final page = rows.take(lim).toList();
      return {
        'blobs': [
          for (final b in page) {...b}..remove('ciphertext'),
        ],
        'cursor': page.isEmpty ? cur : page.last['vcursor'],
        'more': rows.length > lim,
        'key_epoch': epoch,
      };
    };
    api.handlers['/vault/get'] = (a) {
      var budget = maxGetBytes;
      final out = <Map<String, Object?>>[];
      final missing = <String>[];
      final truncated = <String>[];
      for (final id in (a['blob_ids']! as List).cast<String>()) {
        final b = blobs.where((b) => b['blob_id'] == id).toList();
        if (b.isEmpty) {
          missing.add(id);
          continue;
        }
        final size = b.first['size']! as int;
        if (size > budget) {
          truncated.add(id);
          continue;
        }
        budget -= size;
        out.add({...b.first});
      }
      return {'blobs': out, 'missing': missing, 'truncated': truncated};
    };
  }
}

Map<String, Object?> devMap(String id, Identity i, {String name = 'dev'}) => {
  ...deviceMap(id, name: name),
  'public_key': toHex(i.publicKey),
  'revoked_at': null,
};

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase adb;
  late Repo repo;
  late FakeBridgeApi api;
  late BridgeService svc;
  late Identity mine;
  late Identity theirs;
  late VaultServer server;
  late MemorySecretStore secrets;

  BridgeService make() => BridgeService(
    repo: repo,
    ownDeviceId: () => me,
    identity: () => mine,
    apiFactory: (_, _) => api,
    secrets: secrets,
    sendAsB: (c, t) async => 0,
  );

  Future<void> connect({
    bool vaultInUse = false,
    String stateId = 'st1',
  }) async {
    api.connect(helloFor(me, stateId: stateId, vaultInUse: vaultInUse));
    await svc.flushEvents();
    await svc.vault.whenIdle();
  }

  Future<int> addOwn(
    String hash,
    String text, {
    String status = 'sent',
    bool incoming = false,
    int ts = 1700000000000,
  }) async {
    final chat = await repo.findOrCreateChat('B', peer, title: 'Peer');
    if (incoming) {
      return repo.insertIncoming(
        identity: 'B',
        chatId: chat,
        lxmfHash: hash,
        text: text,
        ts: DateTime.fromMillisecondsSinceEpoch(ts),
        route: 'direct',
        transport: 'tcp',
        signatureValid: true,
      );
    }
    final ids = await repo.insertOutgoing(
      identity: 'B',
      chatId: chat,
      destinationHash: peer,
      text: text,
      route: 'opportunistic',
      transport: 'tcp',
    );
    await repo.updateMessage(ids.messageId, lxmfHash: hash, status: status);
    return ids.messageId;
  }

  Map<int, Uint8List> chainOf(VaultService v) => v.keys.chain;

  /// A blob of the other device, encrypted like the app does.
  Future<Map<String, Object?>> otherBlob(
    Map<int, Uint8List> chain,
    int seq,
    List<Map<String, Object?>> records, {
    int epoch = 1,
    String device = '',
    String? blobId,
    int? outerSeq,
  }) async {
    final dev = device.isEmpty ? other : device;
    final id = blobId ?? toHex(secureRandomBytes(16));
    final ct = await VaultCrypto.encryptBlob(
      groupKey: chain[epoch]!,
      blobId: id,
      deviceId: dev,
      seq: seq,
      keyEpoch: epoch,
      kind: 'messages',
      ts: 1700000000.0,
      data: {'records': records},
    );
    return {
      'vcursor': server.blobs.length + 1,
      'blob_id': id,
      'device_id': dev,
      'seq': outerSeq ?? seq,
      'key_epoch': epoch,
      'size': ct.length,
      'ciphertext': ct,
    };
  }

  Map<String, Object?> rec(String hash, String text, {String state = 'sent'}) =>
      {
        'hash': hash,
        'peer': peer,
        'peer_name': 'Peer',
        'incoming': false,
        'title': '',
        'text': text,
        'ts': 1700000000.0,
        'rts': 1700000001.0,
        'state': state,
        'method': 'direct',
        'transport': 'tcp',
        'error': null,
      };

  setUp(() async {
    adb = await AppDatabase.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    repo = Repo(adb);
    api = FakeBridgeApi(vaultStubs: false);
    mine = await Identity.generate();
    theirs = await Identity.generate();
    secrets = MemorySecretStore();
    server = VaultServer(api, {
      me: (devMap(me, mine, name: 'This'), mine),
      other: (devMap(other, theirs, name: 'Phone'), theirs),
    })..install();
    api.handlers['/sync_chats'] = (a) => {
      'state_id': 'st1',
      'cursor': 0,
      'reset': false,
      'more': false,
      'lxmf': <Object?>[],
      'rrc': <Object?>[],
    };
    api.handlers['/list_rooms'] = (a) => {'hubs': []};
    svc = make();
    await svc.configure('bridge public key: ${'cd' * 64}');
  });

  tearDown(() async {
    await svc.stop();
    await adb.close();
  });

  group('activation', () {
    test(
      'first device generates GK1 and wraps it for every trusted device',
      () async {
        await connect();
        expect(server.inUse, isTrue);
        expect(server.wrapped.keys.toSet(), {me, other});
        final mineChain = await VaultCrypto.unwrapFromIdentity(
          server.wrapped[me]!,
          mine,
        );
        final theirChain = await VaultCrypto.unwrapFromIdentity(
          server.wrapped[other]!,
          theirs,
        );
        expect(mineChain!.keys, [1]);
        expect(toHex(theirChain![1]!), toHex(mineChain[1]!));
        expect(toHex(chainOf(svc.vault)[1]!), toHex(mineChain[1]!));
        // not wrappable by a third party
        expect(
          await VaultCrypto.unwrapFromIdentity(
            server.wrapped[me]!,
            await Identity.generate(),
          ),
          isNull,
        );
      },
    );

    test('a revoked device is not wrapped for', () async {
      server.devices[other]!.$1['revoked_at'] = 3.0;
      await connect();
      expect(server.wrapped.keys.toSet(), {me});
    });

    test(
      'losing the race: keys_already_set, the winner key is unwrapped',
      () async {
        // the other device activated between our /vault/key and /vault/set_keys
        final winner = {1: VaultCrypto.generateGroupKey()};
        var first = true;
        final realKey = api.handlers['/vault/key']!;
        api.handlers['/vault/key'] = (a) {
          if (first) {
            first = false;
            return {
              'key_epoch': 1,
              'in_use': false,
              'wrapped_epoch': null,
              'wrapped_group_key': null,
              'wrap': null,
            };
          }
          return realKey(a);
        };
        server.inUse = true;
        server.wrapped[me] = await VaultCrypto.wrapToIdentity(
          winner,
          Identity.fromPublicKey(mine.publicKey),
        );
        server.wrapKind[me] = 'identity';
        await connect();
        expect(toHex(chainOf(svc.vault)[1]!), toHex(winner[1]!));
        // it tried once, lost, and never overwrote the winner's wrap
        expect(api.callsTo('/vault/set_keys'), hasLength(1));
      },
      skip: false,
    );

    test(
      'vault in use, no local chain: unwrap what another device wrapped',
      () async {
        final gk = {1: VaultCrypto.generateGroupKey()};
        server.inUse = true;
        server.wrapped[me] = await VaultCrypto.wrapToIdentity(
          gk,
          Identity.fromPublicKey(mine.publicKey),
        );
        server.wrapKind[me] = 'identity';
        await connect(vaultInUse: true);
        expect(toHex(chainOf(svc.vault)[1]!), toHex(gk[1]!));
        expect((await svc.vault.snapshot()).state, VaultState.idle);
      },
    );

    test(
      'invite-wrapped key is opened with the secret from the QR code',
      () async {
        final gk = {
          1: VaultCrypto.generateGroupKey(),
          2: VaultCrypto.generateGroupKey(),
        };
        final secret = secureRandomBytes(32);
        server
          ..inUse = true
          ..epoch = 2;
        server.wrapped[me] = await VaultCrypto.wrapToInvite(gk, secret);
        server.wrapKind[me] = 'invite';
        await svc.vault.rememberInviteSecret(secret);
        await connect(vaultInUse: true);
        expect(chainOf(svc.vault).keys.toSet(), {1, 2});
      },
    );

    test(
      'no usable key: a clear "waiting for key" state, nothing uploaded',
      () async {
        server.inUse = true; // nobody wrapped a key for this device
        await addOwn('a1' * 16, 'hello');
        await connect(vaultInUse: true);
        final st = await svc.vault.snapshot();
        expect(st.state, VaultState.needsKey);
        expect(server.putLog, isEmpty);
        // and it cannot hand a key on
        final p = PairingPayload(
          pubkey: (await Identity.generate()).publicKey,
          name: 'x',
          platform: 'linux',
          nonce: Uint8List(16),
          ts: 1,
        );
        await expectLater(
          svc.approveDevice(decodePairingQr(encodePairingQr(p))),
          throwsA(isA<VaultKeyMissing>()),
        );
        expect(server.approves, isEmpty);
        await expectLater(svc.createInvite(), throwsA(isA<VaultKeyMissing>()));
      },
    );
  });

  group('approve, invite and revoke while the vault is in use', () {
    test('approve wraps the whole chain to the new device identity', () async {
      await connect();
      final fresh = await Identity.generate();
      final p = PairingPayload(
        pubkey: fresh.publicKey,
        name: 'Tablet',
        platform: 'android',
        nonce: Uint8List(16),
        ts: 1700000000,
      );
      await svc.approveDevice(decodePairingQr(encodePairingQr(p)));
      final a = server.approves.single;
      expect(a['key_epoch'], 1);
      final got = await VaultCrypto.unwrapFromIdentity(
        a['wrapped_group_key']! as Uint8List,
        fresh,
      );
      expect(toHex(got![1]!), toHex(chainOf(svc.vault)[1]!));
    });

    test('approve while the vault is not in use sends no key fields', () async {
      server.devices.remove(other); // a single device: no activation conflict
      api.handlers['/vault/set_keys'] = (a) => throw BridgeError('internal');
      await connect();
      expect(server.inUse, isFalse);
      final p = PairingPayload(
        pubkey: (await Identity.generate()).publicKey,
        name: 'x',
        platform: 'linux',
        nonce: Uint8List(16),
        ts: 1,
      );
      await svc.approveDevice(decodePairingQr(encodePairingQr(p)));
      expect(server.approves.single.containsKey('wrapped_group_key'), isFalse);
      expect(server.approves.single.containsKey('key_epoch'), isFalse);
    });

    test(
      'invite: the chain is wrapped to a secret that only the QR carries',
      () async {
        await connect();
        final qr = await svc.createInvite();
        final inv = decodeInviteQr(qr.text);
        expect(inv.inviteSecret, isNotNull);
        expect(inv.inviteSecret!.length, 32);
        final sent = api.callsTo('/devices/invite').single;
        expect(sent['key_epoch'], 1);
        expect(
          sent.containsKey('invite_secret'),
          isFalse,
        ); // never to the bridge
        final got = await VaultCrypto.unwrapFromInvite(
          sent['wrapped_group_key']! as Uint8List,
          inv.inviteSecret!,
        );
        expect(toHex(got![1]!), toHex(chainOf(svc.vault)[1]!));
      },
    );

    test(
      'revoke rotates: new random GK2, all epochs, every remaining device',
      () async {
        await connect();
        final third = await Identity.generate();
        server.devices['dd' * 16] = (
          devMap('dd' * 16, third, name: 'Third'),
          third,
        );
        server.wrapped['dd' * 16] = Uint8List(1);
        final gk1 = chainOf(svc.vault)[1]!;
        await svc.revokeDevice(other, reason: 'lost');
        final r = server.revokes.single;
        expect(r['key_epoch'], 2);
        final w = (r['wrapped_group_keys']! as Map).cast<String, Uint8List>();
        expect(w.keys.toSet(), {me, 'dd' * 16}); // not the revoked one
        final forThird = await VaultCrypto.unwrapFromIdentity(
          w['dd' * 16]!,
          third,
        );
        expect(forThird!.keys.toSet(), {1, 2});
        expect(toHex(forThird[1]!), toHex(gk1));
        expect(toHex(forThird[2]!), isNot(toHex(gk1))); // fresh, not derived
        expect(chainOf(svc.vault).keys.toSet(), {1, 2});
        expect(server.epoch, 2);
      },
    );

    test('revoke retries once after key_epoch_stale', () async {
      await connect();
      server.revokeStaleLeft = 1;
      await svc.revokeDevice(other);
      expect(server.revokes, hasLength(2));
      expect(server.revokes.last['key_epoch'], 3); // refetched epoch + 1
      expect(server.epoch, 3);
    });
  });

  group('uploader', () {
    test(
      'backfills the whole B history oldest first, never account A',
      () async {
        await addOwn('b2' * 16, 'second', ts: 1700000002000);
        await addOwn('b1' * 16, 'first', ts: 1700000001000);
        await addOwn('b3' * 16, 'in', incoming: true, ts: 1700000003000);
        final chatA = await repo.findOrCreateChat('A', peer, title: 'via');
        await repo.insertIncoming(
          identity: 'A',
          chatId: chatA,
          lxmfHash: 'aa' * 16,
          text: 'secret A',
          ts: DateTime.now(),
          route: 'via_bridge',
          transport: 'tcp',
          signatureValid: true,
        );
        await connect();
        expect(server.putLog, hasLength(1));
        final p = server.putLog.single;
        expect(p['seq'], 1);
        expect(p['device_id'], me);
        final plain = await VaultCrypto.decryptBlob(
          ciphertext: p['ciphertext']! as Uint8List,
          chain: chainOf(svc.vault),
          blobId: p['blob_id']! as String,
          deviceId: me,
          seq: 1,
          keyEpoch: 1,
        );
        final records = ((plain.data! as Map)['records'] as List).cast<Map>();
        // oldest first by message time: the incoming one is from 2023, the two
        // outgoing ones were created now, in this order
        expect(records.map((r) => r['text']), ['in', 'second', 'first']);
        expect(records.every((r) => r['text'] != 'secret A'), isTrue);
        expect(records.first['incoming'], isTrue);
        expect(await svc.vault.store.lastSeq(), 1);
        // nothing left: a later pass sends nothing
        await svc.vault.onKeysMayHaveChanged();
        expect(server.putLog, hasLength(1));
      },
    );

    test(
      'a status change is uploaded as a new record, later rts wins',
      () async {
        final id = await addOwn('b1' * 16, 'hi', status: 'sending');
        await connect();
        expect(server.putLog, hasLength(1));
        await repo.updateMessage(id, status: 'delivered');
        await svc.vault.onKeysMayHaveChanged();
        expect(server.putLog, hasLength(2));
        expect(server.putLog.last['seq'], 2);
      },
    );

    test(
      'large history is split into blobs within vault_max_blob_bytes',
      () async {
        for (var i = 0; i < 40; i++) {
          await addOwn(
            toHex(Uint8List(16)..[0] = i + 1),
            'x' * 3000,
            ts: 1700000000000 + i,
          );
        }
        api.connect(
          HelloResult.fromMap({
            ...{
              'protocol_version': 2,
              'min_protocol_version': 2,
              'max_protocol_version': 2,
              'server': 's',
              'time': 1.0,
              'state_id': 'st1',
              'cursor': 0,
              'device': deviceMap(me, bootstrap: true),
              'capabilities': <String>[],
              'compat': {'ok': true},
              'vault': {'key_epoch': 1, 'in_use': false, 'used_bytes': 0},
              'limits': {'vault_max_blob_bytes': 20000},
            },
          }),
        );
        await svc.flushEvents();
        await svc.vault.whenIdle();
        expect(server.putLog.length, greaterThan(4));
        for (final p in server.putLog) {
          expect(
            (p['ciphertext']! as Uint8List).length,
            lessThanOrEqualTo(20000),
          );
        }
        expect(server.putLog.map((p) => p['seq']), [
          for (var i = 1; i <= server.putLog.length; i++) i,
        ]);
        expect(await svc.vault.store.candidates(10), isEmpty);
      },
    );

    test('idempotent retry: the pending blob is stored before the put and '
        'resent unchanged', () async {
      await addOwn('b1' * 16, 'hello');
      server.putFailuresLeft = 1; // stored, but the response is lost
      await connect();
      final pend = await svc.vault.store.pending();
      expect(pend, isNotNull); // still pending: the app never saw the answer
      expect(server.blobs, hasLength(1));
      // new records appear meanwhile: they must not change the pending blob
      await addOwn('b2' * 16, 'later');
      await svc.vault.onKeysMayHaveChanged();
      expect(server.putLog.length, greaterThanOrEqualTo(2));
      final first = server.putLog[0];
      final retry = server.putLog[1];
      expect(retry['blob_id'], first['blob_id']);
      expect(retry['seq'], first['seq']);
      expect(
        toHex(retry['ciphertext']! as Uint8List),
        toHex(first['ciphertext']! as Uint8List),
      );
      expect(
        server.blobs.where((b) => b['blob_id'] == first['blob_id']),
        hasLength(1),
      ); // the bridge saw one blob
      expect(await svc.vault.store.pending(), isNull);
      // the later message went out in the next blob with the next seq
      expect(server.blobs.map((b) => b['seq']), [1, 2]);
    });

    test('seq_conflict: continues after details.last_seq', () async {
      await addOwn('b1' * 16, 'hello');
      server.lastSeq[me] = 7; // e.g. the app database was lost earlier
      await connect();
      expect(server.putLog.map((p) => p['seq']), [1, 8]);
      expect(await svc.vault.store.lastSeq(), 8);
    });

    test('quota_exceeded stops uploads and shows it', () async {
      await addOwn('b1' * 16, 'hello');
      server.quota = 10;
      await connect();
      final st = await svc.vault.snapshot();
      expect(st.state, VaultState.quotaFull);
      expect(st.quotaBytes, 10);
      expect(await svc.vault.store.pending(), isNotNull);
    });

    test(
      'key_epoch_stale (a revocation): re-encrypts with the new key',
      () async {
        await connect();
        // another device revokes someone: epoch 2 and a new chain for us
        final chain2 = {
          ...chainOf(svc.vault),
          2: VaultCrypto.generateGroupKey(),
        };
        server.wrapped[me] = await VaultCrypto.wrapToIdentity(
          chain2,
          Identity.fromPublicKey(mine.publicKey),
        );
        server.epoch = 2;
        await addOwn('b1' * 16, 'after rotation');
        await svc.vault.onKeysMayHaveChanged();
        final last = server.putLog.last;
        expect(last['key_epoch'], 2);
        final plain = await VaultCrypto.decryptBlob(
          ciphertext: last['ciphertext']! as Uint8List,
          chain: chain2,
          blobId: last['blob_id']! as String,
          deviceId: me,
          seq: last['seq']! as int,
          keyEpoch: 2,
        );
        expect(((plain.data! as Map)['records'] as List), hasLength(1));
      },
    );
  });

  group('downloader', () {
    test('decrypts another device blob into a read-only remote chat', () async {
      await connect();
      final chain = chainOf(svc.vault);
      server.blobs.add(
        await otherBlob(chain, 1, [
          rec('c1' * 16, 'from the phone'),
          rec('c2' * 16, 'second', state: 'delivered'),
        ]),
      );
      await svc.vault.onBlobPush();
      final chats = await repo.remoteChats();
      expect(chats, hasLength(1));
      final c = chats.single;
      expect(c.isRemote, isTrue);
      expect(c.id, lessThan(0));
      expect(c.remoteDeviceId, other);
      expect(c.title, 'Peer');
      final msgs = await repo.messages(c.id);
      expect(msgs.map((m) => m.text), ['from the phone', 'second']);
      expect(msgs.last.status, 'delivered');
      expect(msgs.first.originDevice, other);
      expect(await svc.vault.store.cursor(), 1);
      expect((await svc.vault.snapshot()).remoteDevices, 1);
      // own chats are untouched, remote chats are separate
      expect(await repo.chats(), isEmpty);
    });

    test(
      'a later record for the same message wins; stale ones do not',
      () async {
        await connect();
        final chain = chainOf(svc.vault);
        server.blobs.add(
          await otherBlob(chain, 1, [rec('c1' * 16, 't', state: 'sending')]),
        );
        server.blobs.add(
          await otherBlob(chain, 2, [
            {...rec('c1' * 16, 't', state: 'delivered'), 'rts': 1700000009.0},
          ]),
        );
        server.blobs.add(
          await otherBlob(chain, 3, [
            {...rec('c1' * 16, 't', state: 'sent'), 'rts': 1700000002.0},
          ]),
        );
        await svc.vault.onBlobPush();
        final c = (await repo.remoteChats()).single;
        expect((await repo.messages(c.id)).single.status, 'delivered');
      },
    );

    test('own blobs are skipped but the cursor advances', () async {
      await addOwn('b1' * 16, 'mine');
      await connect();
      expect(await repo.remoteChats(), isEmpty);
      await svc.vault.onBlobPush(); // the next pass sees our own blob
      expect(await svc.vault.store.cursor(), 1);
    });

    test('a seq gap waits (not yet uploaded), then continues', () async {
      await connect();
      final chain = chainOf(svc.vault);
      server.blobs.add(await otherBlob(chain, 1, [rec('c1' * 16, 'one')]));
      server.blobs.add(await otherBlob(chain, 3, [rec('c3' * 16, 'three')]));
      await svc.vault.onBlobPush();
      var c = (await repo.remoteChats()).single;
      expect((await repo.messages(c.id)).map((m) => m.text), ['one']);
      // not advanced past the gap (blob 1 is done, blob 3 waits)
      expect(await svc.vault.store.cursor(), 1);
      // the missing blob appears (vcursor order: it must come before 3)
      server.blobs.insert(
        1,
        await otherBlob(chain, 2, [rec('c2' * 16, 'two')]),
      );
      for (var i = 0; i < server.blobs.length; i++) {
        server.blobs[i]['vcursor'] = i + 1;
      }
      await svc.vault.onBlobPush();
      c = (await repo.remoteChats()).single;
      expect((await repo.messages(c.id)).map((m) => m.text), [
        'one',
        'two',
        'three',
      ]);
    });

    test('truncated responses are re-asked with fewer ids', () async {
      await connect();
      final chain = chainOf(svc.vault);
      for (var i = 1; i <= 5; i++) {
        server.blobs.add(
          await otherBlob(chain, i, [
            rec(toHex(Uint8List(16)..[0] = i), 'm$i'),
          ]),
        );
      }
      server.maxGetBytes =
          (server.blobs.first['size']! as int) + 10; // one at a time
      await svc.vault.onBlobPush();
      final c = (await repo.remoteChats()).single;
      expect(await repo.messages(c.id), hasLength(5));
      expect(api.callsTo('/vault/get').length, greaterThan(1));
    });

    test(
      'bad blobs are skipped, never crash and never retried forever',
      () async {
        await connect();
        final chain = chainOf(svc.vault);
        final wrongKey = {1: VaultCrypto.generateGroupKey()};
        // 1: encrypted with an unrelated key, 2: inner metadata mismatch,
        // 3: garbage, 4: good
        server.blobs.add(await otherBlob(wrongKey, 1, [rec('c1' * 16, 'x')]));
        server.blobs.add(
          await otherBlob(chain, 5, [rec('c2' * 16, 'x')], outerSeq: 2),
        );
        server.blobs.add({
          'vcursor': 3,
          'blob_id': toHex(secureRandomBytes(16)),
          'device_id': other,
          'seq': 3,
          'key_epoch': 1,
          'size': 40,
          'ciphertext': Uint8List.fromList(List.filled(40, 7)),
        });
        server.blobs.add(await otherBlob(chain, 4, [rec('c4' * 16, 'good')]));
        await svc.vault.onBlobPush();
        final c = (await repo.remoteChats()).single;
        expect((await repo.messages(c.id)).map((m) => m.text), ['good']);
        expect(await svc.vault.store.cursor(), 4);
        expect((await svc.vault.snapshot()).skippedBlobs, 3);
        final calls = api.callsTo('/vault/get').length;
        await svc.vault.onBlobPush();
        expect(api.callsTo('/vault/get').length, calls); // nothing re-fetched
      },
    );
  });

  group('field fixes', () {
    test('a seq gap of one device does not block the others', () async {
      await connect();
      final chain = chainOf(svc.vault);
      final third = 'cc' * 16;
      server.blobs.add(await otherBlob(chain, 1, [rec('c1' * 16, 'one')]));
      server.blobs.add(await otherBlob(chain, 3, [rec('c3' * 16, 'three')]));
      server.blobs.add(
        await otherBlob(chain, 1, [
          rec('d1' * 16, 'from third'),
        ], device: third),
      );
      for (var i = 0; i < server.blobs.length; i++) {
        server.blobs[i]['vcursor'] = i + 1;
      }
      await svc.vault.onBlobPush();
      final chats = await repo.remoteChats();
      expect(chats.map((c) => c.remoteDeviceId).toSet(), {other, third});
      final snap = await svc.vault.snapshot();
      expect(snap.downloaded, {other: 1, third: 1});
      // the gap is read again: the saved cursor stays in front of it
      expect(await svc.vault.store.cursor(), 1);
    });

    test('a message that arrives while a pass runs is uploaded too', () async {
      final orig = api.handlers['/vault/put']!;
      var first = true;
      api.handlers['/vault/put'] = (a) async {
        if (first) {
          first = false;
          await addOwn('b2' * 16, 'typed during the upload', ts: 1700000009000);
        }
        return orig(a);
      };
      await addOwn('b1' * 16, 'first');
      await connect();
      expect(server.putLog.length, 2);
      expect(await svc.vault.store.hasUploadWork(), isFalse);
    });

    test('the own history is uploaded although the download fails', () async {
      api.handlers['/vault/list'] = (a) => throw BridgeError('internal', 'x');
      await addOwn('b1' * 16, 'mine');
      await connect();
      expect(server.blobs, hasLength(1));
      final snap = await svc.vault.snapshot();
      expect(snap.state, VaultState.error);
      expect(snap.lastError, 'download: internal');
    });

    test(
      '"sync now" recovers from an error; diagnostics count blobs',
      () async {
        final orig = api.handlers['/vault/list']!;
        var broken = true;
        api.handlers['/vault/list'] = (a) =>
            broken ? throw BridgeError('internal', 'x') : orig(a);
        await addOwn('b1' * 16, 'mine');
        await connect();
        expect((await svc.vault.snapshot()).state, VaultState.error);
        broken = false;
        server.blobs.add(
          await otherBlob(chainOf(svc.vault), 1, [rec('c1' * 16, 'x')]),
        );
        server.blobs.last['vcursor'] = server.blobs.length;
        await svc.vault.syncNow();
        await svc.vault.whenIdle();
        final snap = await svc.vault.snapshot();
        expect(snap.state, VaultState.idle);
        expect(snap.lastError, isNull);
        expect(snap.uploadedBlobs, 1);
        expect(snap.downloaded, {other: 1});
      },
    );

    test('the history sync runs although MeshChatX is down', () async {
      api.handlers['/sync_chats'] = (a) =>
          throw BridgeError('upstream_unavailable', 'x', {'retry_after': 10});
      api.handlers['/list_rooms'] = (a) =>
          throw BridgeError('upstream_unavailable', 'x');
      await addOwn('b1' * 16, 'mine');
      await connect();
      expect(server.blobs, hasLength(1));
      expect(svc.upstreamOk, isFalse);
    });

    test('the history sync runs although the chat sync blows up', () async {
      api.handlers['/sync_chats'] = (a) => throw StateError('boom');
      await addOwn('b1' * 16, 'mine');
      await connect();
      expect(server.blobs, hasLength(1));
    });

    test(
      'a malformed blob is skipped; later blobs and own uploads go on',
      () async {
        await connect();
        final chain = chainOf(svc.vault);
        // valid crypto, but records whose fields have the wrong types
        server.blobs.add(
          await otherBlob(chain, 1, [
            {'hash': 5, 'peer': [], 'text': null, 'ts': 'x'},
            {...rec('c0' * 16, 'x'), 'peer_name': 7, 'title': 3},
          ]),
        );
        server.blobs.add(await otherBlob(chain, 2, [rec('c2' * 16, 'good')]));
        for (var i = 0; i < server.blobs.length; i++) {
          server.blobs[i]['vcursor'] = i + 1;
        }
        await addOwn('b1' * 16, 'mine');
        await svc.vault.onBlobPush();
        final c = (await repo.remoteChats()).single;
        expect(
          (await repo.messages(c.id)).map((m) => m.text),
          contains('good'),
        );
        expect(server.putLog, isNotEmpty);
        expect((await svc.vault.snapshot()).downloaded[other], 2);
      },
    );

    test('an invite-adopted device (iPhone) downloads a blob pushed later '
        'and shows it as a remote chat', () async {
      final gk = {1: VaultCrypto.generateGroupKey()};
      final secret = secureRandomBytes(32);
      server
        ..inUse = true
        ..epoch = 1;
      server.wrapped[me] = await VaultCrypto.wrapToInvite(gk, secret);
      server.wrapKind[me] = 'invite';
      await svc.vault.rememberInviteSecret(secret);
      await connect(vaultInUse: true);
      expect(chainOf(svc.vault).keys.toSet(), {1});
      // the other device uploads AFTER this one connected: only the
      // vault.blob push (topic `vault`) tells it
      server.blobs.add(
        await otherBlob(gk, 1, [rec('c1' * 16, 'from windows')]),
      );
      api.push('vault.blob', {'blob_id': 'x'});
      await svc.flushEvents();
      await svc.vault.whenIdle();
      final c = (await repo.remoteChats()).single;
      expect((await repo.messages(c.id)).single.text, 'from windows');
    });

    test('a vault.blob push downloads another device history', () async {
      await connect();
      server.blobs.add(
        await otherBlob(chainOf(svc.vault), 1, [rec('c1' * 16, 'hello')]),
      );
      api.push('vault.blob', {'blob_id': 'x'});
      await svc.flushEvents();
      await svc.vault.whenIdle();
      expect(await repo.remoteChats(), hasLength(1));
    });
  });

  group('bridge off', () {
    test(
      'drops remote histories, keeps own B data, chain and upload progress',
      () async {
        final own = await addOwn('b1' * 16, 'mine');
        await connect();
        final chain = chainOf(svc.vault);
        server.blobs.add(await otherBlob(chain, 1, [rec('c1' * 16, 'remote')]));
        await svc.vault.onBlobPush();
        expect(await repo.remoteChats(), hasLength(1));
        final seqBefore = await svc.vault.store.lastSeq();
        expect(seqBefore, 1);

        await svc.turnOff();

        expect(await repo.remoteChats(), isEmpty);
        expect(await svc.vault.store.cursor(), 0);
        expect(
          (await repo.messages((await repo.chats()).single.id)).single.id,
          own,
        );
        expect(await svc.vault.store.lastSeq(), seqBefore); // continues later
        await svc.vault.keys.load();
        expect(svc.vault.keys.chain.keys, [1]);
        final stored = json.decode(
          (await secrets.read('kestrel.vault.keys.v1'))!,
        ) as Map<String, Object?>;
        expect((stored['chain']! as String).isNotEmpty, isTrue);
        expect(svc.vault.state, VaultState.off);
      },
    );

    test(
      'a new bridge database (state_id changed) resets the vault state',
      () async {
        await addOwn('b1' * 16, 'mine');
        await connect();
        expect(server.putLog, hasLength(1));
        // the bridge lost its database: empty vault, new state id
        server.blobs.clear();
        server.lastSeq.clear();
        server.inUse = false;
        server.wrapped.clear();
        api.disconnect();
        api.up = true;
        await connect(stateId: 'st2');
        expect(server.inUse, isTrue);
        expect(server.putLog, hasLength(2)); // backfilled again from seq 1
        expect(server.putLog.last['seq'], 1);
      },
    );
  });
}
