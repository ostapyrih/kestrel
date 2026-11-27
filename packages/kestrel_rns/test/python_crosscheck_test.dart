@Tags(['python'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import 'support/vectors.dart';

/// Locates a Python interpreter with rns+lxmf: `$KESTREL_PYTHON`, else
/// `tools/.venv`.
String? findPython() {
  final env = Platform.environment['KESTREL_PYTHON'];
  if (env != null && env.isNotEmpty) return env;
  for (final p in const [
    '../../tools/.venv/Scripts/python.exe',
    '../../tools/.venv/bin/python',
  ]) {
    if (File(p).existsSync()) return File(p).absolute.path;
  }
  return null;
}

Uint8List rnd(Random r, int n) =>
    Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));

void main() {
  final python = findPython();
  final script = File('../../tools/verify_dart_output.py');

  test(
    'python reference accepts random Dart output',
    () async {
      final r = Random.secure();
      final a = await Identity.generate();
      final b = await Identity.generate();
      final named = {'a': a, 'b': b};
      final lxmfHash = {
        for (final e in named.entries) e.key: LXMessage.deliveryHash(e.value)
      };

      final signatures = <Map<String, Object?>>[];
      for (var i = 0; i < 8; i++) {
        final msg = rnd(r, r.nextInt(300));
        signatures.add({
          'public_key': hex(a.publicKey),
          'message': hex(msg),
          'signature': hex(await a.sign(msg)),
        });
      }

      final encrypted = <Map<String, Object?>>[];
      for (var i = 0; i < 8; i++) {
        final pt = rnd(r, r.nextInt(400));
        final ratchetPrv = Identity.generateRatchet();
        final useRatchet = i.isOdd;
        final ct = await Identity.fromPublicKey(b.publicKey).encrypt(
          pt,
          ratchet:
              useRatchet ? await Identity.ratchetPublicBytes(ratchetPrv) : null,
        );
        encrypted.add({
          'recipient': 'b',
          'plaintext': hex(pt),
          'ciphertext': hex(ct),
          'ratchet_private': useRatchet ? hex(ratchetPrv) : null,
        });
      }

      final tokens = <Map<String, Object?>>[];
      for (final len in [32, 64]) {
        final key = rnd(r, len);
        final pt = rnd(r, r.nextInt(200));
        tokens.add({
          'key': hex(key),
          'plaintext': hex(pt),
          'token': hex(await Token(key).encrypt(pt)),
        });
      }

      final announces = <Map<String, Object?>>[];
      for (final withRatchet in [false, true]) {
        final dest = Destination.single(a, 'lxmf', const ['delivery']);
        final p = await Announce.build(
          dest,
          appData: rnd(r, 12),
          ratchetPublic: withRatchet
              ? await Identity.ratchetPublicBytes(Identity.generateRatchet())
              : null,
        );
        announces.add({
          'raw': hex(p.pack()),
          'packet_hash': hex(p.packetHash),
          'destination_hash': hex(dest.hash),
        });
      }

      final lxmf = <Map<String, Object?>>[];
      for (var i = 0; i < 5; i++) {
        final ts = DateTime.now().microsecondsSinceEpoch / 1e6;
        final content = 'Привіт $i ☃ ${base64.encode(rnd(r, 20))}';
        final m = LXMessage(
          destinationHash: lxmfHash['b']!,
          sourceHash: lxmfHash['a']!,
          content: content,
          title: 'title $i',
          timestamp: ts,
          fields: {
            LxmfField.fileAttachments: [
              ['f$i.bin', rnd(r, 30)],
            ],
            LxmfField.customData: {
              'n': -i,
              'f': i / 3,
              'ok': i.isEven,
              'none': null
            },
            0x7F: rnd(r, 8),
          },
        );
        final stamp = i == 4 ? rnd(r, 16) : null;
        final packed = await m.pack(a, stamp: stamp);
        lxmf.add({
          'name': 'rand$i',
          'packed': hex(packed),
          'hash': hex(m.hash!),
          'content': content,
          'title': 'title $i',
          'timestamp': ts,
          'stamp': stamp == null ? null : hex(stamp),
        });
      }

      final packets = <Map<String, Object?>>[];
      for (var i = 0; i < 4; i++) {
        final p = Packet(
          destinationHash: rnd(r, 16),
          data: rnd(r, 1 + r.nextInt(400)),
          context: r.nextInt(256),
          hops: r.nextInt(128),
          headerType: i.isOdd ? Packet.header2 : Packet.header1,
          transportId: i.isOdd ? rnd(r, 16) : null,
          transportType: i.isOdd ? Packet.transport : Packet.broadcast,
        );
        packets.add({'raw': hex(p.pack()), 'packet_hash': hex(p.packetHash)});
      }

      final hdlc = <Map<String, Object?>>[];
      for (var i = 0; i < 6; i++) {
        final payload = rnd(r, 20 + r.nextInt(300));
        // sprinkle specials
        for (var k = 0; k < 5 && payload.length > k; k++) {
          payload[r.nextInt(payload.length)] = r.nextBool() ? 0x7E : 0x7D;
        }
        hdlc.add({'payload': hex(payload), 'frame': hex(Hdlc.frame(payload))});
      }

      // Vault envelope (docs/bridge-protocol.md 9.4) produced by Dart with real randomness.
      final chain = {
        1: VaultCrypto.generateGroupKey(),
        2: VaultCrypto.generateGroupKey(),
      };
      final inviteSecret = rnd(r, 32);
      final blobData = {
        'messages': [
          {'hash': hex(rnd(r, 16)), 'text': 'Привіт ☃', 'ts': 1.5, 'n': -4}
        ]
      };
      final blobId = hex(rnd(r, 16));
      final deviceId = hex(rnd(r, 16));
      final vault = {
        'recipient': 'b',
        'chain_packed': hex(VaultCrypto.packChain(chain)),
        'wrapped_identity': hex(await VaultCrypto.wrapToIdentity(
            chain, Identity.fromPublicKey(b.publicKey))),
        'wrapped_invite': hex(await VaultCrypto.wrapToInvite(chain, inviteSecret)),
        'invite_secret': hex(inviteSecret),
        'group_keys': {for (final e in chain.entries) '${e.key}': hex(e.value)},
        'blob': {
          'blob_id': blobId,
          'device_id': deviceId,
          'seq': 3,
          'key_epoch': 2,
          'kind': 'messages',
          'ts': 1700000000.5,
          'data_packed': hex(packb(blobData)),
          'ciphertext': hex(await VaultCrypto.encryptBlob(
            groupKey: chain[2]!,
            blobId: blobId,
            deviceId: deviceId,
            seq: 3,
            keyEpoch: 2,
            kind: 'messages',
            ts: 1700000000.5,
            data: blobData,
          )),
        },
      };

      final out = {
        'vault': vault,
        'identities': [
          for (final e in named.entries)
            {
              'name': e.key,
              'private_key': hex(e.value.privateKey!),
              'public_key': hex(e.value.publicKey),
              'hash': hex(e.value.hash),
              'lxmf_delivery_hash': hex(lxmfHash[e.key]!),
            },
        ],
        'signatures': signatures,
        'encrypted': encrypted,
        'tokens': tokens,
        'announces': announces,
        'lxmf': lxmf,
        'packets': packets,
        'hdlc': hdlc,
      };
      final dir = Directory.systemTemp.createTempSync('kestrel_xcheck');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/dart_output.json')
        ..writeAsStringSync(json.encode(out));

      final res =
          await Process.run(python!, ['-I', script.absolute.path, file.path]);
      // ignore: avoid_print
      print('${res.stdout}${res.stderr}');
      expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
    },
    skip: (python == null || !script.existsSync())
        ? 'python venv with rns+lxmf not found (tools/.venv or \$KESTREL_PYTHON)'
        : false,
  );
}
