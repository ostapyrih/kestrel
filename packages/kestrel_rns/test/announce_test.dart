import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import 'support/vectors.dart';

void main() {
  final av = loadVectors('announce.json');
  late Identity alice;
  setUpAll(() async {
    alice = (await loadIdentities([asMap(av['identity'])]))['alice']!;
  });

  for (final r in maps(av['announces'])) {
    group(r['name']! as String, () {
      test('build == python (byte for byte)', () async {
        final aspects = (r['aspects']! as List<Object?>).cast<String>();
        final dest =
            Destination.single(alice, r['app_name']! as String, aspects);
        expect(hex(dest.hash), r['destination_hash']);
        expect(hex(dest.nameHash), r['name_hash']);
        final p = await Announce.build(
          dest,
          appData:
              r['app_data'] == null ? null : unhex(r['app_data'] as String?),
          ratchetPublic: r['ratchet_public'] == null
              ? null
              : unhex(r['ratchet_public'] as String?),
          randomHash: unhex(r['random_hash_10'] as String?),
          pathResponse: r['path_response']! as bool,
        );
        expect(hex(p.pack()), r['raw']);
        expect(hex(p.data), r['announce_data']);
        expect(hex(p.packetHash), r['packet_hash']);
      });

      test('validate python announce', () async {
        final p = Packet.unpack(unhex(r['raw'] as String?));
        final a = await Announce.validate(p);
        expect(a, isNotNull);
        expect(hex(a!.destinationHash), r['destination_hash']);
        expect(hex(a.publicKey), asMap(av['identity'])['public_key']);
        expect(hex(a.identity.hash), asMap(av['identity'])['hash']);
        expect(hex(a.nameHash), r['name_hash']);
        expect(hex(a.appData), r['app_data'] ?? '');
        expect(a.hasRatchet, r['ratchet_public'] != null);
        expect(a.hasRatchet ? hex(a.ratchet) : null, r['ratchet_public']);
        expect(a.emittedAt, r['timestamp']);
      });
    });
  }

  test('ext payload trailer is detected but left in app_data', () async {
    final r = maps(av['announces'])
        .firstWhere((x) => x['name'] == 'appdata_with_ext_payload');
    final a =
        await Announce.validate(Packet.unpack(unhex(r['raw'] as String?)));
    expect(a!.stampTrailer, isNotNull);
    expect(a.stampTrailer!.stamp.length, Announce.stampLength);
    final plain = maps(av['announces'])
        .firstWhere((x) => x['name'] == 'lxmf_delivery_plain');
    final b =
        await Announce.validate(Packet.unpack(unhex(plain['raw'] as String?)));
    expect(b!.stampTrailer, isNull);
  });

  test('transport re-emitted (HEADER_2) announce validates', () async {
    final h2 = asMap(av['transport_reemitted']);
    final p = Packet.unpack(unhex(h2['raw'] as String?));
    expect(p.headerType, Packet.header2);
    expect(p.hops, 1);
    expect(hex(p.transportId!), h2['transport_id']);
    expect(hex(p.packetHash), h2['packet_hash']);
    expect(await Announce.validate(p), isNotNull);
  });

  for (final r in maps(av['invalid'])) {
    test('rejects ${r['name']}', () async {
      final p = Packet.tryUnpack(unhex(r['raw'] as String?));
      if (p == null) return;
      expect(await Announce.validate(p), isNull);
    });
  }

  test('random announce validates', () async {
    final id = await Identity.generate();
    final dest = Destination.single(id, 'kestrel', const ['bridge']);
    final ratchet =
        await Identity.ratchetPublicBytes(Identity.generateRatchet());
    final p =
        await Announce.build(dest, appData: [1, 2, 3], ratchetPublic: ratchet);
    final a = await Announce.validate(Packet.unpack(p.pack()));
    expect(a, isNotNull);
    expect(a!.ratchet, ratchet);
  });
}
