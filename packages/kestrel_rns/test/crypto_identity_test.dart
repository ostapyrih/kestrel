import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import 'support/vectors.dart';

void main() {
  final idv = loadVectors('identity.json');
  final tokv = loadVectors('token.json');

  group('hashes', () {
    for (final h in maps(idv['hashes'])) {
      final data = unhex(h['data'] as String?);
      test('sha/truncated ${data.length}B', () {
        expect(hex(sha256(data)), h['sha256']);
        expect(hex(truncatedHash(data)), h['truncated']);
        expect(hex(sha512(data)), h['sha512']);
      });
    }
  });

  group('hkdf', () {
    for (final v in maps(tokv['hkdf'])) {
      test('length ${v['length']} salt=${v['salt'] != null}', () {
        final out = hkdf(
          length: v['length']! as int,
          deriveFrom: unhex(v['derive_from'] as String?),
          salt: v['salt'] == null ? null : unhex(v['salt'] as String?),
          context: v['context'] == null ? null : unhex(v['context'] as String?),
        );
        expect(hex(out), v['output']);
      });
    }
  });

  group('token', () {
    for (final v in maps(tokv['tokens'])) {
      final key = unhex(v['key'] as String?);
      final pt = unhex(v['plaintext'] as String?);
      test('${v['mode']} ${pt.length}B encrypt == python', () async {
        final t = await Token(key).encrypt(pt, iv: unhex(v['iv'] as String?));
        expect(hex(t), v['token']);
      });
      test('${v['mode']} ${pt.length}B decrypt python token', () async {
        final out = await Token(key).decrypt(unhex(v['token'] as String?));
        expect(out, pt);
      });
    }
    for (final v in maps(tokv['invalid_tokens'])) {
      test('rejects ${v['name']}', () {
        expect(
          Token(unhex(v['key'] as String?))
              .decrypt(unhex(v['token'] as String?)),
          throwsA(isA<TokenException>()),
        );
      });
    }
    for (final v in maps(tokv['lax_padding'])) {
      test('python-lax padding ${v['name']}', () async {
        final out = await Token(unhex(v['key'] as String?))
            .decrypt(unhex(v['token'] as String?));
        expect(hex(out), v['plaintext']);
      });
    }
    test('random IV round trip', () async {
      final t = Token(Token.generateKey());
      final a = await t.encrypt([1, 2, 3]);
      final b = await t.encrypt([1, 2, 3]);
      expect(a, isNot(b));
      expect(await t.decrypt(a), [1, 2, 3]);
    });
  });

  group('identity', () {
    late Map<String, Identity> ids;
    final recs = maps(idv['identities']);
    setUpAll(() async => ids = await loadIdentities(recs));

    test('keys and hashes match python', () {
      for (final r in recs) {
        final i = ids[r['name']]!;
        expect(hex(i.x25519Public), r['x25519_public']);
        expect(hex(i.ed25519Public), r['ed25519_public']);
        expect(hex(i.publicKey), r['public_key']);
        expect(hex(i.hash), r['hash']);
        expect(hex(i.privateKey!), r['private_key']);
      }
    });

    test('signatures identical to python (Ed25519 deterministic)', () async {
      for (final s in maps(idv['signatures'])) {
        final id = ids[s['identity']]!;
        final msg = unhex(s['message'] as String?);
        final sig = await id.sign(msg);
        expect(hex(sig), s['signature']);
        expect(
            await id.validate(unhex(s['signature'] as String?), msg), isTrue);
      }
    });

    test('rejects invalid signatures', () async {
      for (final s in maps(idv['invalid_signatures'])) {
        final id = ids[s['identity']]!;
        expect(
          await id.validate(
            unhex(s['signature'] as String?),
            unhex(s['message'] as String?),
          ),
          isFalse,
          reason: '$s',
        );
      }
      expect(
          await ids['alice']!.validate(Uint8List(10), Uint8List(1)), isFalse);
    });

    test('encrypt with fixed ephemeral/IV == python ciphertext', () async {
      for (final e in maps(idv['encrypt'])) {
        final rcpt = Identity.fromPublicKey(ids[e['recipient']]!.publicKey);
        final ct = await rcpt.encrypt(
          unhex(e['plaintext'] as String?),
          ephemeralPrivate: unhex(e['ephemeral_private'] as String?),
          iv: unhex(e['iv'] as String?),
          ratchet: e['ratchet_public'] == null
              ? null
              : unhex(e['ratchet_public'] as String?),
        );
        expect(hex(ct), e['ciphertext'], reason: '${e['name']}');
      }
    });

    test('decrypts python ciphertext', () async {
      for (final e in maps(idv['encrypt'])) {
        final rcpt = ids[e['recipient']]!;
        final ratchets = e['ratchet_private'] == null
            ? null
            : [unhex(e['ratchet_private'] as String?)];
        final pt = await rcpt.decrypt(
          unhex(e['ciphertext'] as String?),
          ratchets: ratchets,
        );
        expect(hex(pt!), e['plaintext'], reason: '${e['name']}');
      }
    });

    test('ratchet ciphertext not decryptable by identity key alone', () async {
      final e = maps(idv['encrypt']).firstWhere((x) => x['name'] == 'ratchet');
      expect(
        await ids['bob']!.decrypt(unhex(e['ciphertext'] as String?)),
        isNull,
      );
      final seen = <Uint8List?>[];
      final pt = await ids['bob']!.decrypt(
        unhex(e['ciphertext'] as String?),
        ratchets: [unhex(e['ratchet_private'] as String?)],
        enforceRatchets: true,
        onRatchetId: seen.add,
      );
      expect(pt, isNotNull);
      expect(
        seen.single,
        Identity.ratchetId(unhex(e['ratchet_public'] as String?)),
      );
    });

    test('decrypt failures return null', () async {
      for (final f in maps(idv['decrypt_failures'])) {
        expect(
          await ids[f['recipient']]!.decrypt(unhex(f['ciphertext'] as String?)),
          isNull,
          reason: '${f['name']}',
        );
      }
    });

    test('random generate/encrypt/decrypt round trip', () async {
      final a = await Identity.generate();
      final ct = await Identity.fromPublicKey(a.publicKey).encrypt([9, 8, 7]);
      expect(await a.decrypt(ct), [9, 8, 7]);
    });

    test('public-only identity cannot sign/decrypt', () {
      final p = Identity.fromPublicKey(ids['alice']!.publicKey);
      expect(() => p.sign([1]), throwsStateError);
      expect(() => p.decrypt([1]), throwsStateError);
    });
  });
}
