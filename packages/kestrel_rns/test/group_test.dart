import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

Future<GroupDevice> _dev(String name, {int added = 1000}) async =>
    GroupDevice.of(await Identity.generate(),
        name: name, platform: 'test', addedAt: added);

void main() {
  group('DeviceList', () {
    test('merge is order independent; higher revision wins', () async {
      final a = await _dev('A');
      final b = await _dev('B');
      final l1 = DeviceList([a.copy(), b.copy()]);
      final l2 = DeviceList([a.copy(), b.copy()]);
      l1.rename(a.id, 'A renamed');
      l2.remove(b.id);
      final m1 = DeviceList(l1.all.map((d) => d.copy()))..merge(l2.all);
      final m2 = DeviceList(l2.all.map((d) => d.copy()))..merge(l1.all);
      for (final m in [m1, m2]) {
        expect(m[a.id]!.name, 'A renamed');
        expect(m[b.id]!.removed, isTrue);
        expect(m.active.map((d) => d.id), [a.id]);
      }
      expect(m1.merge(l1.all), isFalse, reason: 'idempotent');
    });

    test('a tombstone beats a put of equal revision and is never undone',
        () async {
      final a = await _dev('A');
      final l = DeviceList([a.copy()]);
      final stale = a.copy();
      l.remove(a.id);
      expect(l.merge([stale]), isFalse);
      expect(l[a.id]!.removed, isTrue);
    });

    test('records with a forged id or malformed fields are dropped', () async {
      final a = await _dev('A');
      final b = await _dev('B');
      final forged = a.toMap()..['id'] = b.id;
      expect(GroupDevice.fromMap(forged), isNull);
      expect(GroupDevice.fromMap({'id': 1}), isNull);
      expect(GroupDevice.fromMap(a.toMap())!.id, a.id);
      expect(DeviceList.fromList([forged, a.toMap(), 3]).all.length, 1);
    });
  });

  group('GroupState', () {
    test('create, encode, decode round trip', () async {
      final a = await _dev('A');
      final s = GroupState.create(a, displayName: 'Alice');
      s.timebase = 1234;
      final d = GroupState.decode(s.encode())!;
      expect(d.groupId, s.groupId);
      expect(d.epoch, 1);
      expect(d.currentKey, s.currentKey);
      expect(d.displayName, 'Alice');
      expect(d.devices.active.single.id, a.id);
      expect(d.timebase, 1234);
      expect(GroupState.decode([1, 2, 3]), isNull);
    });

    test('removing a device rotates the key to a fresh random epoch', () async {
      final a = await _dev('A');
      final b = await _dev('B');
      final s = GroupState.create(a)..devices.put(b);
      final k1 = s.currentKey;
      final removed = s.removeDevice(b.id)!;
      expect(removed.removed, isTrue);
      expect(s.epoch, 2);
      expect(s.currentKey, isNot(k1));
      expect(s.chain[1], k1, reason: 'old epochs stay readable');
      expect(s.removeDevice(b.id), isNull);
      expect(s.epoch, 2);
    });

    test('a removed device cannot read blobs of the new epoch', () async {
      final a = await _dev('A');
      final b = await _dev('B');
      final s = GroupState.create(a)..devices.put(b);
      final bView = GroupState.decode(s.encode())!; // b before removal
      s.removeDevice(b.id);
      final ct = await VaultCrypto.encryptBlob(
        groupKey: s.currentKey,
        blobId: 'b1',
        deviceId: a.id,
        seq: 1,
        keyEpoch: s.epoch,
        kind: 'x',
        ts: 1,
        data: {'n': 1},
      );
      await expectLater(
        VaultCrypto.decryptBlob(
            ciphertext: ct,
            chain: bView.chain,
            blobId: 'b1',
            deviceId: a.id,
            seq: 1,
            keyEpoch: s.epoch),
        throwsA(isA<VaultCryptoException>()),
      );
      expect(
          (await VaultCrypto.decryptBlob(
                  ciphertext: ct,
                  chain: s.chain,
                  blobId: 'b1',
                  deviceId: a.id,
                  seq: 1,
                  keyEpoch: s.epoch))
              .data,
          {'n': 1});
    });

    test('name: higher revision wins, ties are deterministic', () async {
      final s = GroupState.create(await _dev('A'), displayName: 'x');
      expect(s.mergeName('older', 0), isFalse);
      expect(s.mergeName('newer', 5), isTrue);
      expect(s.nameRev, 5);
      expect(s.mergeName('zzz', 5), isTrue);
      expect(s.mergeName('aaa', 5), isFalse);
      s.setName('mine');
      expect(s.nameRev, 6);
    });

    test('chain and timebase only move forward', () async {
      final s = GroupState.create(await _dev('A'));
      final k2 = VaultCrypto.generateGroupKey();
      expect(s.mergeChain({2: k2}), isTrue);
      expect(s.epoch, 2);
      expect(s.mergeChain({1: Uint8List(32)}), isFalse,
          reason: 'known epochs are never overwritten');
      expect(s.mergeTimebase(10), isTrue);
      expect(s.mergeTimebase(9), isFalse);
    });
  });

  group('PairingBundle and invite', () {
    test('bundle round trip', () async {
      final g = await Identity.generate();
      final s = GroupState.create(await _dev('A'), displayName: 'Alice');
      final b = PairingBundle(
        groupPrivateKey: g.privateKey!,
        state: s,
        ratchets: [RatchetEntry(Identity.generateRatchet(), 55)],
        stamp: Uint8List(14)..[0] = 7,
      );
      final r = PairingBundle.unpack(b.pack())!;
      expect(r.groupPrivateKey, g.privateKey);
      expect(r.state.groupId, s.groupId);
      expect(r.ratchets.single.createdAt, 55);
      expect(r.stamp![0], 7);
      expect(PairingBundle.unpack(Uint8List(5)), isNull);
    });

    test('invite QR text round trips and rejects garbage', () async {
      final host = await Identity.generate();
      final inv = PairingInvite(
        hostPublicKey: host.publicKey,
        secret: Uint8List.fromList(List.generate(32, (i) => i)),
        expiresAt: 2000000000,
        hostName: 'Phone',
      );
      final txt = inv.encode();
      expect(txt, startsWith('kestrel-group:v1:'));
      expect(txt.contains('='), isFalse);
      final p = PairingInvite.parse('  $txt\n')!;
      expect(p.hostPublicKey, host.publicKey);
      expect(p.secret, inv.secret);
      expect(p.expiresAt, 2000000000);
      expect(p.hostName, 'Phone');
      expect(PairingInvite.parse('kestrel-pair:v1:abc'), isNull);
      expect(PairingInvite.parse('kestrel-group:v1:%%%'), isNull);
      expect(inv.expired(nowSeconds: 2000000001), isTrue);
      expect(inv.expired(nowSeconds: 5), isFalse);
    });

    test('comparison code is 6 digits and depends on secret and link', () {
      final s1 = Uint8List(32);
      final s2 = Uint8List(32)..[0] = 1;
      final l = Uint8List(16);
      final c = pairingCode(s1, l);
      expect(c, matches(RegExp(r'^\d{6}$')));
      expect(pairingCode(s1, l), c);
      expect(pairingCode(s2, l), isNot(c));
      expect(pairingCode(s1, Uint8List(16)..[3] = 9), isNot(c));
    });
  });
}
