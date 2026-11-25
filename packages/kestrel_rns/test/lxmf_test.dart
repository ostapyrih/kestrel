import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import 'support/vectors.dart';

double _f(String bits) => floatFromBits(bits);

void main() {
  final lv = loadVectors('lxmf.json');
  late Map<String, Identity> ids;
  setUpAll(() async => ids = await loadIdentities(maps(lv['identities'])));

  test('constants match python', () {
    expect(LXMessage.lxmfOverhead, lv['lxmf_overhead']);
    expect(LXMessage.encryptedPacketMaxContent,
        lv['encrypted_packet_max_content']);
    expect(LXMessage.linkPacketMaxContent, lv['link_packet_max_content']);
    expect(LXMessage.destinationLength, lv['destination_length']);
    expect(LXMessage.signatureLength, lv['signature_length']);
    final f = asMap(lv['fields']);
    expect(LxmfField.fileAttachments, f['FIELD_FILE_ATTACHMENTS']);
    expect(LxmfField.image, f['FIELD_IMAGE']);
    expect(LxmfField.replyTo, f['FIELD_REPLY_TO']);
    expect(LxmfField.reaction, f['FIELD_REACTION']);
    expect(LxmfField.debug, f['FIELD_DEBUG']);
    expect(LxmfField.customData, f['FIELD_CUSTOM_DATA']);
  });

  for (final m in maps(lv['messages'])) {
    group(m['name']! as String, () {
      test('pack == python (hash, signature, bytes)', () async {
        final msg = LXMessage(
          destinationHash: unhex(m['destination_hash'] as String?),
          sourceHash: unhex(m['source_hash'] as String?),
          title: unhex(m['title'] as String?),
          content: unhex(m['content'] as String?),
          fields: fromTree(m['fields'])! as Map<Object?, Object?>,
          timestamp: _f(m['timestamp_bits']! as String),
          desiredMethod: m['desired_method']! as int,
        );
        final stamp = m['stamp'] == null ? null : unhex(m['stamp'] as String?);
        // For ticket-stamped messages the stamp must equal the ticket stamp.
        if (m['ticket'] != null) {
          // hash is stamp-independent: pack once without stamp to get id
          final probe = LXMessage(
            destinationHash: msg.destinationHash,
            sourceHash: msg.sourceHash,
            title: msg.title,
            content: msg.content,
            fields: msg.fields,
            timestamp: msg.timestamp,
          );
          await probe.pack(ids[m['source_identity']]!);
          expect(
            hex(LXMessage.ticketStamp(
                unhex(m['ticket'] as String?), probe.hash!)),
            m['stamp'],
          );
        }
        final packed = await msg.pack(ids[m['source_identity']]!, stamp: stamp);
        expect(hex(packed), m['packed']);
        expect(hex(msg.hash!), m['message_hash']);
        expect(hex(msg.signature!), m['signature']);
        expect(msg.method, m['method']);
        expect(msg.representation, m['representation']);
      });

      test('unpack python bytes (with and without source identity)', () async {
        final bytes = unhex(m['packed'] as String?);
        final unknown = await LXMessage.unpackFromBytes(bytes);
        expect(unknown.signatureValidated, isFalse);
        expect(unknown.unverifiedReason, LxmfUnverifiedReason.sourceUnknown);
        expect(hex(unknown.hash!), m['message_hash']);

        final v = await LXMessage.unpackFromBytes(
          bytes,
          sourceIdentity: Identity.fromPublicKey(ids['alice']!.publicKey),
        );
        expect(v.signatureValidated, isTrue);
        expect(hex(v.hash!), m['message_hash']);
        expect(hex(v.destinationHash), m['destination_hash']);
        expect(hex(v.sourceHash), m['source_hash']);
        expect(hex(v.title), m['title']);
        expect(hex(v.content), m['content']);
        expect(v.timestamp, _f(m['timestamp_bits']! as String));
        expect(deepEquals(v.fields, fromTree(m['fields'])), isTrue);
        expect(v.stamp == null ? null : hex(v.stamp!), m['stamp']);
        if (m['content_utf8'] != null) {
          expect(v.contentAsString, m['content_utf8']);
        }
      });
    });
  }

  group('wire forms', () {
    for (final w in maps(lv['wire_forms'])) {
      final name = w['message']! as String;
      final m = maps(lv['messages']).firstWhere((x) => x['name'] == name);
      test('$name opportunistic payload / packet', () async {
        final msg =
            await LXMessage.unpackFromBytes(unhex(m['packed'] as String?));
        expect(hex(msg.opportunisticPayload), w['opportunistic_payload']);
        final bob = Identity.fromPublicKey(ids['bob']!.publicKey);
        final enc = await bob.encrypt(
          msg.opportunisticPayload,
          ephemeralPrivate: unhex(w['ephemeral_private'] as String?),
          iv: unhex(w['iv'] as String?),
        );
        expect(hex(enc), w['encrypted_payload']);
        if (w['packet_raw'] != null) {
          final bobDest = Destination.single(bob, 'lxmf', const ['delivery']);
          final pkt = Packet(
            destinationHash: bobDest.hash,
            data: enc,
          );
          expect(hex(pkt.pack()), w['packet_raw']);
          expect(hex(pkt.packetHash), w['packet_hash']);
          // Receiver side
          final rx = Packet.unpack(unhex(w['packet_raw'] as String?));
          final pt = await ids['bob']!.decrypt(rx.data);
          final full =
              LXMessage.fromOpportunisticPayload(rx.destinationHash, pt!);
          expect(hex(full), m['packed']);
        }
      });
      test('$name propagated form', () async {
        final msg =
            await LXMessage.unpackFromBytes(unhex(m['packed'] as String?));
        final pp = await msg.propagationPacked(
          Identity.fromPublicKey(ids['bob']!.publicKey),
          now: (w['propagation_now']! as num).toDouble(),
          ephemeralPrivate: unhex(w['ephemeral_private'] as String?),
          iv: unhex(w['iv'] as String?),
        );
        expect(hex(pp.packed), w['propagation_packed']);
        expect(hex(pp.transientId), w['transient_id']);
      });
    }
  });

  test('tampered messages fail signature validation', () async {
    for (final t in maps(lv['invalid_signatures'])) {
      final m = await LXMessage.unpackFromBytes(
        unhex(t['packed'] as String?),
        sourceIdentity: Identity.fromPublicKey(ids['alice']!.publicKey),
      );
      expect(m.signatureValidated, isFalse, reason: '${t['name']}');
      expect(m.unverifiedReason, t['unverified_reason']);
    }
  });

  test('random message round trip', () async {
    final a = await Identity.generate();
    final b = await Identity.generate();
    final msg = LXMessage(
      destinationHash: LXMessage.deliveryHash(b),
      sourceHash: LXMessage.deliveryHash(a),
      content: 'hi',
      title: 't',
      fields: {
        1: 'x',
        2: Uint8List.fromList([1])
      },
    );
    final packed = await msg.pack(a);
    final back = await LXMessage.unpackFromBytes(packed, sourceIdentity: a);
    expect(back.signatureValidated, isTrue);
    expect(back.contentAsString, 'hi');
    expect(back.hash, msg.hash);
  });
}
