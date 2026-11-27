import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import 'support/vectors.dart';

void main() {
  final v = loadVectors('vault.json');
  final idv = loadVectors('identity.json');
  final bobRec =
      maps(idv['identities']).firstWhere((i) => i['name'] == v['recipient']);
  late Identity bob;
  final gk = {
    for (final e in asMap(v['group_keys']).entries)
      int.parse(e.key): unhex(e.value as String?)
  };

  setUpAll(() async {
    bob = await Identity.fromPrivateKey(unhex(bobRec['private_key'] as String?));
  });

  test('chain packs byte-identically to Python', () {
    expect(hex(VaultCrypto.packChain(gk)), v['chain_packed']);
    final back = VaultCrypto.unpackChain(unhex(v['chain_packed'] as String?));
    expect(back.keys.toList(), [1, 2]);
    expect(hex(back[2]!), hex(gk[2]!));
  });

  test('chain wrapped to an identity: Dart produces and opens the same bytes',
      () async {
    final w = asMap(v['wrap_identity']);
    final mine = await VaultCrypto.wrapToIdentity(
      gk,
      Identity.fromPublicKey(bob.publicKey),
      ephemeralPrivate: unhex(w['ephemeral_private'] as String?),
      iv: unhex(w['iv'] as String?),
    );
    expect(hex(mine), w['wrapped']);
    final opened = await VaultCrypto.unwrapFromIdentity(
        unhex(w['wrapped'] as String?), bob);
    expect(opened, isNotNull);
    expect(hex(opened![1]!), hex(gk[1]!));
    final other = await Identity.generate();
    expect(await VaultCrypto.unwrapFromIdentity(mine, other), isNull);
  });

  test('per-epoch keys match', () {
    for (final e in asMap(v['epoch_keys']).entries) {
      final epoch = int.parse(e.key);
      expect(hex(VaultCrypto.epochKey(gk[epoch]!, epoch)), e.value);
    }
  });

  test('invite wrap matches and needs the right secret', () async {
    final inv = asMap(v['invite']);
    final secret = unhex(inv['secret'] as String?);
    expect(hex(VaultCrypto.inviteKey(secret)), inv['key']);
    final mine = await VaultCrypto.wrapToInvite(gk, secret,
        iv: unhex(inv['iv'] as String?));
    expect(hex(mine), inv['wrapped']);
    final opened = await VaultCrypto.unwrapFromInvite(mine, secret);
    expect(hex(opened![2]!), hex(gk[2]!));
    expect(await VaultCrypto.unwrapFromInvite(mine, Uint8List(32)), isNull);
  });

  group('blobs', () {
    for (final b in maps(v['blobs'])) {
      test('epoch ${b['key_epoch']} blob decrypts and re-encrypts identically',
          () async {
        final plain = await VaultCrypto.decryptBlob(
          ciphertext: unhex(b['ciphertext'] as String?),
          chain: gk,
          blobId: b['blob_id']! as String,
          deviceId: b['device_id']! as String,
          seq: b['seq']! as int,
          keyEpoch: b['key_epoch']! as int,
        );
        expect(plain.kind, b['kind']);
        expect(plain.ts, b['ts']);
        expect(hex(packb(plain.data)), b['data_packed']);
        final again = await VaultCrypto.encryptBlob(
          groupKey: gk[b['key_epoch']! as int]!,
          blobId: b['blob_id']! as String,
          deviceId: b['device_id']! as String,
          seq: b['seq']! as int,
          keyEpoch: b['key_epoch']! as int,
          kind: b['kind']! as String,
          ts: (b['ts']! as num).toDouble(),
          data: plain.data,
          iv: unhex(b['iv'] as String?),
        );
        expect(hex(again), b['ciphertext']);
      });
    }

    test('inner metadata must equal the outer one', () async {
      final m = asMap(v['mismatch']);
      expect(
        VaultCrypto.decryptBlob(
          ciphertext: unhex(m['ciphertext'] as String?),
          chain: gk,
          blobId: m['blob_id']! as String,
          deviceId: m['device_id']! as String,
          seq: m['claimed_seq']! as int,
          keyEpoch: m['key_epoch']! as int,
        ),
        throwsA(isA<VaultCryptoException>()),
      );
    });

    test('missing epoch key, wrong key and tampering are rejected', () async {
      final b = maps(v['blobs'])[0];
      Future<VaultBlobPlain> open(Uint8List ct, Map<int, Uint8List> chain) =>
          VaultCrypto.decryptBlob(
            ciphertext: ct,
            chain: chain,
            blobId: b['blob_id']! as String,
            deviceId: b['device_id']! as String,
            seq: b['seq']! as int,
            keyEpoch: b['key_epoch']! as int,
          );
      final ct = unhex(b['ciphertext'] as String?);
      await expectLater(open(ct, {2: gk[2]!}),
          throwsA(isA<VaultCryptoException>()));
      await expectLater(open(ct, {1: gk[2]!}),
          throwsA(isA<VaultCryptoException>()));
      final bad = Uint8List.fromList(ct)..[20] ^= 1;
      await expectLater(open(bad, gk), throwsA(isA<VaultCryptoException>()));
    });
  });
}
