import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import 'support/vectors.dart';

void main() {
  final dv = loadVectors('destination.json');
  final pv = loadVectors('packet.json');
  final idv = loadVectors('identity.json');

  group('destination', () {
    late Map<String, Identity> ids;
    setUpAll(() async => ids = await loadIdentities(maps(idv['identities'])));

    for (final d in maps(dv['destinations'])) {
      test(d['full_name'], () {
        final app = d['app_name']! as String;
        final aspects = (d['aspects']! as List<Object?>).cast<String>();
        expect(hex(Destination.nameHashFor(app, aspects)), d['name_hash']);
        expect(
          hex(Destination.nameHashFromFullName(d['full_name']! as String)),
          d['name_hash'],
        );
        for (final p in maps(d['per_identity'])) {
          final id = ids[p['identity']]!;
          final dest = Destination.single(id, app, aspects);
          expect(hex(dest.hash), p['hash']);
          expect(dest.name, p['expanded_name']);
          expect(hex(Destination.hashFor(id.hash, app, aspects)), p['hash']);
        }
        final plain = Destination.plain(app, aspects);
        expect(hex(plain.hash), d['plain_hash']);
        expect(plain.name, d['plain_expanded_name']);
      });
    }

    test('dots rejected', () {
      expect(() => Destination.plain('a.b', const []), throwsArgumentError);
      expect(() => Destination.plain('a', const ['b.c']), throwsArgumentError);
    });
  });

  group('packet', () {
    test('constants match python', () {
      expect(Packet.mtu, pv['mtu']);
      expect(Packet.mdu, pv['mdu']);
      expect(Packet.headerMaxSize, pv['header_maxsize']);
      expect(Packet.headerMinSize, pv['header_minsize']);
      expect(Packet.pathfinderM, pv['pathfinder_m']);
      expect(LXMessage.encryptedPacketMdu, pv['encrypted_mdu']);
      expect(Token.tokenOverhead, pv['token_overhead']);
      final ctx = asMap(pv['contexts']);
      expect(Packet.resource, ctx['RESOURCE']);
      expect(Packet.keepalive, ctx['KEEPALIVE']);
      expect(Packet.lrProof, ctx['LRPROOF']);
      expect(Packet.pathResponse, ctx['PATH_RESPONSE']);
      expect(Packet.channel, ctx['CHANNEL']);
    });

    late Map<String, Identity> ids;
    setUpAll(() async => ids = await loadIdentities(maps(pv['identities'])));

    for (final r in maps(pv['packets'])) {
      test('${r['name']}: pack/unpack/hash == python', () {
        final raw = unhex(r['raw'] as String?);
        // build from fields
        final built = Packet(
          destinationHash: unhex(r['destination_hash'] as String?),
          data: unhex(r['data'] as String?),
          packetType: r['packet_type']! as int,
          context: r['context']! as int,
          headerType: r['header_type']! as int,
          contextFlag: r['context_flag']! as int,
          transportType: r['transport_type']! as int,
          destinationType: r['destination_type']! as int,
          hops: r['hops']! as int,
          transportId: r['transport_id'] == null
              ? null
              : unhex(r['transport_id'] as String?),
        );
        expect(hex(built.pack()), r['raw']);
        expect(built.flags, r['flags']);
        expect(hex(built.hashablePart), r['hashable_part']);
        expect(hex(built.packetHash), r['packet_hash']);
        expect(hex(built.truncatedPacketHash), r['truncated_packet_hash']);

        final p = Packet.unpack(raw);
        expect(p.headerType, r['header_type']);
        expect(p.contextFlag, r['context_flag']);
        expect(p.transportType, r['transport_type']);
        expect(p.destinationType, r['destination_type']);
        expect(p.packetType, r['packet_type']);
        expect(p.context, r['context']);
        expect(p.hops, r['hops']);
        expect(hex(p.destinationHash), r['destination_hash']);
        expect(hex(p.data), r['data']);
        expect(p.transportId == null ? null : hex(p.transportId!),
            r['transport_id']);
        expect(hex(p.packetHash), r['packet_hash']);
        expect(hex(p.pack()), r['raw']);
      });
    }

    test('encrypted payloads decrypt with recipient identity', () async {
      for (final r in maps(pv['packets'])) {
        if (r['recipient'] == null) continue;
        final pt =
            await ids[r['recipient']]!.decrypt(unhex(r['data'] as String?));
        expect(hex(pt!), r['plaintext'], reason: '${r['name']}');
      }
    });

    for (final r in maps(pv['invalid_raw'])) {
      test('rejects ${r['name']}', () {
        expect(Packet.tryUnpack(unhex(r['raw'] as String?)), isNull);
        expect(
          () => Packet.unpack(unhex(r['raw'] as String?)),
          throwsA(isA<PacketException>()),
        );
      });
    }

    test('hops 127 accepted', () {
      expect(
          Packet.tryUnpack(unhex(pv['hops_127_ok_raw'] as String?)), isNotNull);
    });

    test('pack enforces MTU and transport id', () {
      expect(
        () => Packet(
          destinationHash: Uint8List(16),
          data: Uint8List(Packet.mtu),
        ).pack(),
        throwsA(isA<PacketException>()),
      );
      expect(
        () => Packet(
          destinationHash: Uint8List(16),
          data: Uint8List(1),
          headerType: Packet.header2,
        ).pack(),
        throwsA(isA<PacketException>()),
      );
    });
  });
}
