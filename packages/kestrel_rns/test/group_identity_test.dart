import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

void main() {
  group('GroupState identity generation', () {
    test('higher generation wins; same change twice is not newer', () async {
      final s = GroupState.create(
        GroupDevice.of(await Identity.generate(), name: 'A', platform: 't'),
      );
      expect(s.adoptIdentity(1, 'aa'), isTrue);
      expect(s.adoptIdentity(1, 'aa'), isFalse, reason: 'idempotent');
      expect(s.adoptIdentity(1, 'ab'), isTrue, reason: 'tie: larger hash');
      expect(s.adoptIdentity(1, 'aa'), isFalse);
      expect(s.adoptIdentity(0, 'zz'), isFalse, reason: 'older generation');
      expect(s.adoptIdentity(2, '00'), isTrue);
      final r = GroupState.decode(s.encode())!;
      expect(r.identityGen, 2);
      expect(r.identityHash, '00');
    });
  });

  group('identity record', () {
    test('round trip and rejection of malformed data', () async {
      final g = await Identity.generate();
      final c = IdentityChange(
        privateKey: g.privateKey!,
        gen: 3,
        replaces: 'ab' * 16,
        name: 'Alice',
        nameRev: 4,
        ratchets: [RatchetEntry(Identity.generateRatchet(), 99)],
        stamp: Uint8List(8)..[0] = 5,
        timebase: 1234,
      );
      final r = IdentityChange.fromMap(unpackb(packb(c.toMap())))!;
      expect(r.privateKey, g.privateKey);
      expect(r.gen, 3);
      expect(r.replaces, 'ab' * 16);
      expect(r.name, 'Alice');
      expect(r.ratchets.single.createdAt, 99);
      expect(r.stamp![0], 5);
      expect(r.timebase, 1234);
      expect(await r.newHash(), toHex(g.hash));
      expect(IdentityChange.fromMap({'v': 1, 'priv': Uint8List(3)}), isNull);
      expect(IdentityChange.fromMap({'v': 2}), isNull);
    });

    test('a sibling decrypts the envelope, adopts G\' once, switches', () async {
      final rns = await Reticulum.start(
        ReticulumConfig(interfaces: const [], storage: MemoryStorage()),
      );
      final k1 = await Identity.generate();
      final k2 = await Identity.generate();
      final s1 = GroupState.create(
        GroupDevice.of(k1, name: 'D1', platform: 't'),
        displayName: 'Alice',
      );
      final s2 = GroupState.decode(s1.encode())!
        ..devices.put(GroupDevice.of(k2, name: 'D2', platform: 't'));
      s1.devices.put(s2.devices[toHex(k2.hash)]!.copy());

      final router = await LxmRouter.start(rns, k2);
      final switched = <IdentityChange>[];
      var persisted = 0;
      final d2 = DeviceSync(
        rns: rns,
        router: router,
        deviceKey: k2,
        state: s2,
        store: KestrelSyncStore(MemoryStorage()),
        onStateChanged: () => persisted++,
        onIdentity: (c) async => switched.add(c),
      );
      await d2.start();

      final fresh = await Identity.generate();
      final change = IdentityChange(
        privateKey: fresh.privateKey!,
        gen: 1,
        replaces: 'cd' * 16,
        name: 'Alice 2',
        nameRev: 5,
        ratchets: [RatchetEntry(Identity.generateRatchet(), 7)],
        timebase: 42,
      );
      var seq = 0;
      Future<Uint8List> envelope(IdentityChange c) async {
        seq++;
        final id = toHex(truncatedHash('${toHex(k1.hash)}:$seq'.codeUnits));
        return packb({
          'v': kDeviceSyncVersion,
          'blob_id': id,
          'device_id': toHex(k1.hash),
          'seq': seq,
          'key_epoch': s1.epoch,
          'ct': await VaultCrypto.encryptBlob(
            groupKey: s1.currentKey,
            blobId: id,
            deviceId: toHex(k1.hash),
            seq: seq,
            keyEpoch: s1.epoch,
            kind: SyncKind.identity,
            ts: 1.0,
            data: c.toMap(),
          ),
        });
      }

      expect(await d2.ingest(await envelope(change)), isTrue);
      expect(switched, hasLength(1));
      expect(await switched.single.newHash(), toHex(fresh.hash));
      expect(s2.identityGen, 1);
      expect(s2.identityHash, toHex(fresh.hash));
      expect(s2.displayName, 'Alice 2');
      expect(s2.timebase, 42);
      expect(persisted, greaterThan(0));

      // the same change again (new seq) and an older generation do nothing
      await d2.ingest(await envelope(change));
      final older = await Identity.generate();
      await d2.ingest(await envelope(IdentityChange(
        privateKey: older.privateKey!,
        gen: 1,
        replaces: 'cd' * 16,
      )).then((e) => e));
      expect(s2.identityGen, 1);
      expect(
        switched.length,
        // a tie at the same generation is decided by the larger hash
        toHex(older.hash).compareTo(toHex(fresh.hash)) > 0 ? 2 : 1,
      );

      await d2.stop();
      await router.stop();
      await rns.stop();
    });
  });
}
