import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:kestrel_rns/src/crypto/curves.dart' show x25519Exchange;
import 'package:kestrel_rns/src/stamps_table.dart' show stampTab;
import 'package:test/test.dart';

import 'support/vectors.dart';

/// Golden vectors from the Python reference (tools/gen_vectors.py,
/// `network.json`): stamps, link key agreement, request packing and resource
/// advertisement / hashmap structure.
void main() {
  final v = loadVectors('network.json');

  group('stamps', () {
    test('target table equals RNS TAB', () {
      final tab = (v['stamp_tab']! as List<Object?>).cast<String>();
      expect(stampTab.length, tab.length);
      for (var i = 0; i < tab.length; i++) {
        expect(stampTab[i].toRadixString(16), tab[i], reason: 'TAB[$i]');
      }
    });

    test('cost fixed point, bytes and 256-bit target', () {
      for (final c in maps(v['stamp_costs'])) {
        final cost = (c['cost']! as num).toDouble();
        expect(Stamps.costToFp(cost), c['fp'], reason: '$cost');
        expect(hex(Stamps.costToBytes(cost)), c['bytes']);
        expect(
          Stamps.targetFromFp(Stamps.costToFp(cost)),
          BigInt.parse(c['target']! as String, radix: 16),
        );
        expect(Stamps.quantizeCost(cost), (c['quantized']! as num).toDouble());
        expect(
          Stamps.costFromBytes(Stamps.costToBytes(cost)),
          (c['quantized']! as num).toDouble(),
        );
      }
    });

    test('stamp value and validity match Python', () {
      for (final s in maps(v['stamp_values'])) {
        final material = unhex(s['material'] as String);
        final stamp = unhex(s['stamp'] as String);
        expect(
          Stamps.value(material, stamp),
          (s['value']! as num).toDouble(),
        );
        final valid = asMap(s['valid_at']);
        for (final e in valid.entries) {
          expect(
            Stamps.isValid(stamp, double.parse(e.key), material),
            e.value,
            reason: 'cost ${e.key}',
          );
        }
      }
    });

    test('Python-mined stamps validate; Dart generation yields valid stamps',
        () {
      for (final s in maps(v['stamp_mined'])) {
        final material = unhex(s['material'] as String);
        final cost = (s['cost']! as num).toDouble();
        expect(Stamps.isValid(unhex(s['stamp'] as String), cost, material),
            isTrue);
      }
      final material = Uint8List.fromList(List.generate(46, (i) => i));
      final st = Stamps.generate(material, 10)!;
      expect(st.length, 14);
      expect(Stamps.isValid(st, 10, material), isTrue);
      expect(Stamps.value(material, st), greaterThanOrEqualTo(10));
    });

    test('generate honours maxRounds', () {
      expect(Stamps.generate([1, 2, 3], 60, maxRounds: 100), isNull);
    });

    test('generateAsync runs off-isolate', () async {
      final material = Uint8List.fromList(List.generate(30, (i) => 200 - i));
      final st = (await Stamps.generateAsync(material, 9))!;
      expect(Stamps.isValid(st, 9, material), isTrue);
    });

    test('stamped announce: validate and build match Python byte-for-byte',
        () async {
      final ids = await loadIdentities(
          maps(loadVectors('identity.json')['identities']));
      for (final a in maps(v['stamped_announces'])) {
        final raw = unhex(a['raw'] as String);
        final p = Packet.unpack(raw);
        final ann = (await Announce.validate(p, requiredStampCost: 8))!;
        expect(hex(ann.stamp!), a['stamp']);
        expect(ann.stampValue, (a['stamp_value']! as num).toDouble());
        expect(ann.linkCost, 12.5);
        expect(hex(ann.payloadAppData), a['stored_app_data'] ?? '');
        expect(a['python_valid_at_8'], isTrue);

        // required cost above the stamp's value => stamp not valid, the
        // ext payload stays in app_data, announce itself is still valid
        final strict = (await Announce.validate(p, requiredStampCost: 20))!;
        expect(strict.stamp, isNull);
        expect(strict.payloadAppData, strict.appData);
        expect(
            await Announce.validate(p,
                requiredStampCost: 20, enforceStamps: true),
            isNull);

        // rebuild identically
        final dest = Destination.single(
          ids['alice']!,
          a['app_name']! as String,
          (a['aspects']! as List<Object?>).cast<String>(),
        );
        final app = a['app_data'] == null || (a['app_data']! as String).isEmpty
            ? null
            : unhex(a['app_data'] as String);
        final built = await Announce.build(
          dest,
          appData: app,
          stamp: unhex(a['stamp'] as String),
          randomHash: [
            ...unhex(a['random_hash_seed5'] as String),
            ...List.generate(
                5, (i) => ((a['timestamp']! as int) >> (8 * (4 - i))) & 0xFF),
          ],
        );
        expect(hex(built.pack()), a['raw']);
      }
    });
  });

  group('link crypto', () {
    test('signalling bytes', () {
      for (final s in maps(v['signalling'])) {
        expect(
          hex(Link.signallingBytes(s['mtu']! as int, s['mode']! as int)),
          s['bytes'],
        );
      }
    });

    test('keepalive formula', () {
      for (final k in maps(v['keepalive'])) {
        final rtt = (k['rtt']! as num).toDouble();
        final ka = [
          [rtt * (Link.keepaliveMax / Link.keepaliveMaxRtt), 360.0]
              .reduce((a, b) => a < b ? a : b),
          5.0,
        ].reduce((a, b) => a > b ? a : b);
        expect(ka, (k['keepalive']! as num).toDouble());
      }
    });

    test('link id, ECDH + HKDF derived key, token, proof signature', () async {
      final ids = await loadIdentities(
          maps(loadVectors('identity.json')['identities']));
      for (final l in maps(v['links'])) {
        final lr = Packet.unpack(unhex(l['link_request_raw'] as String));
        // link id excludes the signalling bytes
        var hp = lr.hashablePart;
        hp = Uint8List.sublistView(hp, 0, hp.length - 3);
        expect(hex(truncatedHash(hp)), l['link_id']);
        final noSig = Packet.unpack(
            unhex(l['link_request_without_signalling_raw'] as String));
        expect(hex(truncatedHash(noSig.hashablePart)),
            l['link_id_without_signalling']);
        expect(l['link_id'], l['link_id_without_signalling']);

        final linkId = unhex(l['link_id'] as String);
        // both sides derive the same key
        final shared1 = await x25519Exchange(
          unhex(l['initiator_x25519_private'] as String),
          unhex(l['responder_pub'] as String),
        );
        final shared2 = await x25519Exchange(
          unhex(l['responder_x25519_private'] as String),
          unhex(l['initiator_pub'] as String),
        );
        expect(hex(shared1), l['shared_key']);
        expect(hex(shared2), l['shared_key']);
        final key = hkdf(length: 64, deriveFrom: shared1, salt: linkId);
        expect(hex(key), l['derived_key']);

        // token with fixed IV == python ciphertext; python rtt token decrypts
        final token = Token(key);
        final ct = await token.encrypt(
          unhex(l['plaintext'] as String),
          iv: unhex(l['iv'] as String),
        );
        expect(hex(ct), l['ciphertext']);
        expect(hex(await token.decrypt(ct)), l['plaintext']);
        final rtt =
            unpackb(await token.decrypt(unhex(l['rtt_ciphertext'] as String)));
        expect(rtt, (l['rtt']! as num).toDouble());

        // responder proof: signature over link_id|pub|sig_pub|signalling
        final proof = unhex(l['proof_data'] as String);
        final signed = unhex(l['proof_signed_data'] as String);
        expect(
          await ids['bob']!.validate(proof.sublist(0, 64), signed),
          isTrue,
        );
        expect(hex(await ids['bob']!.sign(signed)), hex(proof.sublist(0, 64)));
        expect(hex(proof.sublist(64, 96)), l['responder_pub']);
        expect(hex(proof.sublist(96)), l['signalling']);

        // MDU formula
        final probe = ((l['mtu']! as int) - 1 - 19 - 48) ~/ 16 * 16 - 1;
        expect(probe, l['mdu']);
      }
    });
  });

  group('request / response packing', () {
    test('request, response and request id', () {
      for (final r in maps(v['requests'])) {
        final ph = truncatedHash((r['path']! as String).codeUnits);
        expect(hex(ph), r['path_hash']);
        final packed = packb([
          r['timestamp'],
          ph,
          fromTree(r['data']),
        ]);
        expect(hex(packed), r['packed']);
        final un = unpackb(packed)! as List<Object?>;
        expect(un[0], r['timestamp']);
        final rid = Packet.unpack(unhex(r['request_packet_raw'] as String))
            .truncatedPacketHash;
        expect(hex(rid), r['request_id']);
        expect(
          hex(packb([rid, fromTree(r['response_obj'])])),
          r['packed_response'],
        );
      }
    });
  });

  group('resource', () {
    final consts = asMap(v['resource_constants']);

    test('constants', () {
      expect(ResourceAdvertisement.hashmapMaxLen, consts['hashmap_max_len']);
      expect(ResourceAdvertisement.collisionGuardSize,
          consts['collision_guard_size']);
      expect(Resource.maxEfficientSize, consts['max_efficient_size']);
    });

    test('advertisement unpack/pack, hashes, proof and map hashes', () {
      for (final r in maps(v['resources'])) {
        final name = r['name'];
        final adv = ResourceAdvertisement.unpack(unhex(r['adv'] as String));
        expect(adv.flags, r['flags'], reason: '$name');
        expect(adv.transferSize, r['size']);
        expect(adv.dataSize, r['total_size']);
        expect(adv.parts, (r['parts']! as List<Object?>).length);
        expect(hex(adv.hash), r['hash']);
        expect(hex(adv.randomHash), r['random_hash']);
        expect(adv.compressed, r['compressed']);
        expect(adv.encrypted, isTrue);
        expect(adv.requestId, isNull);

        // re-pack identical (first hashmap segment, same MDU rule)
        expect(
          hex(adv.pack(mdu: r['link_mdu']! as int)),
          r['adv'],
          reason: '$name',
        );
        if (r['adv_segment_1'] != null) {
          // sender-side advertisement holds the full hashmap
          final full = ResourceAdvertisement(
            transferSize: adv.transferSize,
            dataSize: adv.dataSize,
            parts: adv.parts,
            hash: adv.hash,
            randomHash: adv.randomHash,
            originalHash: adv.originalHash,
            hashmap: unhex(r['hashmap'] as String),
            flags: adv.flags,
          );
          expect(hex(full.pack(mdu: r['link_mdu']! as int)), r['adv']);
          expect(hex(full.pack(segment: 1, mdu: r['link_mdu']! as int)),
              r['adv_segment_1']);
        }

        // hash = SHA256(data || random_hash); proof = SHA256(data || hash)
        final data = unhex(r['data'] as String);
        final rh = unhex(r['random_hash'] as String);
        expect(hex(sha256([...data, ...rh])), r['hash']);
        expect(hex(sha256([...data, ...unhex(r['hash'] as String)])),
            r['expected_proof']);

        // hashmap = first 4 bytes of SHA256(part || random_hash)
        final parts = (r['parts']! as List<Object?>).cast<String>();
        final map = BytesBuilder();
        for (final p in parts) {
          map.add(sha256([...unhex(p), ...rh]).sublist(0, 4));
        }
        expect(hex(map.toBytes()), r['hashmap']);

        // stream: random prefix || (compressed?) data, split in sdu parts
        final stream = BytesBuilder();
        for (final p in parts) {
          stream.add(unhex(p));
        }
        final s = stream.toBytes();
        expect(s.length, r['size']);
        final sdu = r['sdu']! as int;
        expect(sdu, (r['mtu']! as int) - 35 - 1);
        expect(parts.length, (s.length + sdu - 1) ~/ sdu);
        final body = s.sublist(4);
        expect(hex(s.sublist(0, 4)), r['random_prefix']);
        final plain = (r['compressed']! as bool)
            ? BZip2Decoder().decodeBytes(body, verify: true)
            : body;
        expect(hex(plain), hex(data));
        expect(hex(sha256([...plain, ...rh])), r['hash']);
        if (r['hmu_segment_1'] != null) {
          final hmu = unhex(r['hmu_segment_1'] as String);
          expect(hex(hmu.sublist(0, 32)), r['hash']);
          final upd = unpackb(hmu.sublist(32))! as List<Object?>;
          expect(upd[0], 1);
          final hm = unhex(r['hashmap'] as String);
          final seg = ResourceAdvertisement.hashmapMaxLen;
          expect(
              hex(upd[1]! as Uint8List),
              hex(hm.sublist(
                  seg * 4, hm.length < 2 * seg * 4 ? hm.length : 2 * seg * 4)));
        }
      }
    });

    test('request / response advertisement flags', () {
      for (final f in maps(v['resource_flagged'])) {
        final adv = ResourceAdvertisement.unpack(unhex(f['adv'] as String));
        expect(adv.flags, f['flags']);
        expect(hex(adv.requestId!), f['request_id']);
        expect(adv.isResponse, f['is_response']);
        expect(adv.isRequest, !(f['is_response']! as bool));
      }
    });

    test('bz2 interop: decode Python-compressed data, python decodes ours', () {
      for (final b in maps(v['bz2'])) {
        final plain = unhex(b['plain'] as String);
        final dec = BZip2Decoder()
            .decodeBytes(unhex(b['compressed'] as String), verify: true);
        expect(hex(dec), hex(plain));
        // round trip through our encoder
        expect(
          hex(BZip2Decoder()
              .decodeBytes(BZip2Encoder().encodeBytes(plain), verify: true)),
          hex(plain),
        );
      }
    });
  });
}
