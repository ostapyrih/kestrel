import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/bridge/bridge_connection.dart';
import 'package:kestrel/bridge/codec.dart';
import 'package:kestrel_rns/kestrel_rns.dart';

import 'support/python_peer.dart' show findPython;

/// Wire shapes against the examples of docs/bridge-protocol.md.
void main() {
  group('responses and records (spec 2.2, 4.1, 6)', () {
    test('ok / error envelopes', () {
      expect(
        BridgeConnection.parseResponse({
          'ok': true,
          'result': {'a': 1},
        }),
        {'a': 1},
      );
      expect(
        () => BridgeConnection.parseResponse({
          'ok': false,
          'error': {
            'code': 'rate_limited',
            'message': 'slow down',
            'details': {'retry_after': 3},
          },
        }),
        throwsA(
          isA<BridgeError>()
              .having((e) => e.code, 'code', 'rate_limited')
              .having((e) => e.retryable, 'retryable', isTrue)
              .having((e) => e.retryAfter, 'retryAfter', 3.0),
        ),
      );
      expect(
        () => BridgeConnection.parseResponse(null),
        throwsA(isA<BridgeTransportError>()),
      );
    });

    test('retryable errors are exactly the ones that release the cmd_id', () {
      for (final c in [
        'upstream_unavailable',
        'upstream_auth',
        'rate_limited',
      ]) {
        expect(BridgeError(c).retryable, isTrue, reason: c);
      }
      for (final c in [
        'send_failed',
        'replay',
        'device_revoked',
        'bad_request',
      ]) {
        expect(BridgeError(c).retryable, isFalse, reason: c);
      }
    });

    test('hello result of the spec (6.1)', () {
      final h = HelloResult.fromMap({
        'protocol_version': 2,
        'min_protocol_version': 2,
        'max_protocol_version': 2,
        'server': 'kestrel-bridge/0.3.0',
        'time': 1700000000.5,
        'state_id': 'abcdef0123456789',
        'cursor': 12,
        'device': {
          'device_id': 'aa' * 16,
          'public_key': 'bb' * 64,
          'name': 'Phone',
          'platform': 'android',
          'roles': ['field'],
          'bootstrap': true,
          'added_by': 'config',
          'added_at': 1.0,
          'last_seen': null,
          'revoked_at': null,
        },
        'capabilities': ['lxmf', 'rrc', 'push'],
        'compat': {
          'ok': false,
          'meshchatx_version': '4.12.1',
          'api_version': 1,
        },
        'profile': 'full',
        'vault': {'key_epoch': 3, 'in_use': true, 'used_bytes': 10},
        'limits': {'max_text_bytes': 4096},
      });
      expect((h.protocolVersion, h.minVersion, h.maxVersion), (2, 2, 2));
      expect(h.stateId, 'abcdef0123456789');
      expect(h.device.isField, isTrue);
      expect(h.device.lastSeen, isNull);
      expect(h.compatOk, isFalse);
      expect((h.vaultInUse, h.vaultKeyEpoch), (true, 3));
    });

    test('sync_chats result (6.2) and messages result (6.3)', () {
      final s = SyncResult.fromMap({
        'state_id': 's',
        'cursor': 4,
        'reset': false,
        'more': true,
        'lxmf': [
          {
            'peer': '11' * 16,
            'name': 'P',
            'last_ts': 'whatever',
            'unread': true,
            'failed': 1,
            'preview': 'hi',
            'last_id': 9,
          },
        ],
        'rrc': [
          {
            'hub': '22' * 16,
            'hub_name': 'H',
            'room': 'general',
            'unread': 2,
            'mention': true,
          },
        ],
      });
      expect((s.cursor, s.more, s.reset), (4, true, false));
      expect((s.lxmf.single.unread, s.lxmf.single.lastId), (true, 9));
      expect((s.rrc.single.room, s.rrc.single.mention), ('general', true));
      final m = MessagesResult.fromMap({
        'peer': '11' * 16,
        'has_more': true,
        'gap': true,
        'messages': [
          {
            'id': 7,
            'hash': 'cc' * 16,
            'incoming': false,
            'state': 'sent',
            'method': 'direct',
            'title': '',
            'text': 'yo',
            'ts': 1700000000,
            'attachments': false,
            'origin_device': 'dd' * 16,
            'cmd_id': 'k123456789',
          },
        ],
      });
      expect((m.hasMore, m.gap), (true, true));
      final x = m.messages.single;
      expect(
        (x.id, x.originDevice, x.cmdId, x.terminal),
        (7, 'dd' * 16, 'k123456789', false),
      );
      expect(x.ts, 1700000000.0); // an integer on the wire is fine
    });

    test('push envelope (2.3)', () {
      final ev = PushEvent.tryParse(
        unpackb(
          packb({
            't': 'push',
            'seq': 3,
            'id': 'ab' * 8,
            'ts': 1700000000.0,
            'event': 'read_state',
            'data': {
              'peer': 'x',
              'unread': false,
              'cursor': 5,
              'by_device': null,
            },
          }),
        ),
      )!;
      expect((ev.seq, ev.id, ev.event), (3, 'ab' * 8, 'read_state'));
      expect(ev.data['by_device'], isNull);
      expect(PushEvent.tryParse({'t': 'other'}), isNull);
      expect(PushEvent.tryParse('junk'), isNull);
    });

    test('kestrel.reject packet (spec 2.4) parses, anything else does not', () {
      final r = RejectPacket.tryParse(
        unpackb(
          packb({
            't': 'kestrel.reject',
            'code': 'unauthorized',
            'server_time': 1700000000.5,
          }),
        ),
      )!;
      expect(
        (r.code, r.serverTime, r.isRevoked),
        ('unauthorized', 1700000000.5, false),
      );
      final v = RejectPacket.tryParse({
        't': 'kestrel.reject',
        'code': 'device_revoked',
      })!;
      expect(v.isRevoked, isTrue);
      expect(v.serverTime, isNull);
      expect(RejectPacket.tryParse({'t': 'push', 'code': 'x'}), isNull);
      expect(RejectPacket.tryParse({'t': 'kestrel.reject'}), isNull);
      expect(RejectPacket.tryParse('junk'), isNull);
      // a reject packet is never mistaken for a push event
      expect(
        PushEvent.tryParse({'t': 'kestrel.reject', 'code': 'unauthorized'}),
        isNull,
      );
    });

    test('request args are string-keyed msgpack maps (round trip)', () {
      final args = {
        'cmd_id': newCmdId(),
        'to': '11' * 16,
        'text': 'hi',
        'delivery_method': null,
      };
      final back = asMap(unpackb(packb(args)));
      expect(back, args);
      expect(cmdIdRe.hasMatch(args['cmd_id']!), isTrue);
      expect(newCmdId(), isNot(newCmdId()));
    });
  });

  group('bridge address', () {
    test('the public key is extracted from --print-address output', () {
      final key = 'ab12' * 32;
      final out =
          'bridge destination (kestrel.bridge): ${'cd' * 16}\n'
          'bridge lxmf.delivery destination:    ${'ef' * 16}\n'
          'bridge public key (hex):             ${key.toUpperCase()}\n';
      expect(extractBridgePublicKey(out), key);
      expect(extractBridgePublicKey(key), key);
      expect(extractBridgePublicKey('no key here ${'ab' * 16}'), isNull);
    });

    test('destination hashes derive from the public key', () async {
      final id = await Identity.generate();
      expect(
        toHex(bridgeDestinationHash(id.publicKey)),
        toHex(Destination.hashFor(id, 'kestrel', const ['bridge'])),
      );
      expect(
        toHex(bridgeLxmfHash(id.publicKey)),
        toHex(Destination.hashFor(id, 'lxmf', const ['delivery'])),
      );
    });
  });

  group('pairing payload (5.1) and signature message (5.2)', () {
    final pub = Uint8List.fromList(List.generate(64, (i) => i));
    final nonce = Uint8List.fromList(List.generate(16, (i) => 200 - i));
    final payload = PairingPayload(
      pubkey: pub,
      name: 'Моя Pixel',
      platform: 'android',
      nonce: nonce,
      ts: 1700000000.25,
    );

    test('QR text: prefix, base64url without padding, bin fields', () {
      final qr = encodePairingQr(payload);
      expect(qr, startsWith('kestrel-pair:v1:'));
      final b64 = qr.substring('kestrel-pair:v1:'.length);
      expect(b64.contains('='), isFalse);
      expect(b64.contains('+') || b64.contains('/'), isFalse);
      final raw = base64Url.decode(
        b64.padRight((b64.length + 3) ~/ 4 * 4, '='),
      );
      final m = unpackb(raw)! as Map<Object?, Object?>;
      expect(m['pubkey'], isA<Uint8List>()); // msgpack bin, not hex
      expect(m['nonce'], isA<Uint8List>());
      expect((m['pubkey']! as Uint8List).length, 64);
      expect(m['name'], 'Моя Pixel');
      expect(m['platform'], 'android');
      expect(m['ts'], 1700000000.25);
    });

    test('decode returns the exact bytes that were encoded', () {
      final d = decodePairingQr(' ${encodePairingQr(payload)}\n');
      expect(d.raw, payload.pack());
      expect(d.payload.pubkey, pub);
      expect(d.payload.nonce, nonce);
      expect(d.payload.name, 'Моя Pixel');
      expect(d.payload.ts, 1700000000.25);
    });

    test('malformed codes are rejected', () {
      expect(() => decodePairingQr('hello'), throwsFormatException);
      expect(
        () => decodePairingQr('kestrel-pair:v1:!!!'),
        throwsFormatException,
      );
      String enc(Map<String, Object?> m) =>
          'kestrel-pair:v1:${base64UrlNoPad(packb(m))}';
      final ok = {
        'pubkey': pub,
        'name': 'n',
        'platform': 'linux',
        'nonce': nonce,
        'ts': 1,
      };
      expect(decodePairingQr(enc(ok)).payload.name, 'n');
      for (final bad in [
        {...ok, 'pubkey': Uint8List(63)},
        {...ok, 'nonce': Uint8List(8)},
        {...ok, 'name': ''},
        {...ok, 'name': 'a\u0001b'},
        {...ok, 'platform': 'Linux!'},
        {...ok, 'ts': 'now'},
      ]) {
        expect(() => decodePairingQr(enc(bad)), throwsFormatException);
      }
    });

    test('signature message = domain || payload || approver id (raw)', () {
      final p = payload.pack();
      final id = '0123456789abcdef0123456789abcdef';
      final msg = pairingSignMessage(p, id);
      expect(msg.sublist(0, 24), utf8.encode('kestrel-pair-approve:v1:'));
      expect(msg.sublist(24, 24 + p.length), p);
      expect(msg.sublist(24 + p.length), fromHex(id));
      expect(msg.length, 24 + p.length + 16);
    });

    test('fingerprint is the device id in groups of four', () {
      expect(formatFingerprint('0123456789abcdef'), '0123 4567 89ab cdef');
      expect(payload.fingerprint.replaceAll(' ', ''), payload.deviceId);
      expect(payload.deviceId.length, 32);
    });

    test('cross-check with the Python bridge implementation', () {
      final py = findPython();
      final script = File('../tools/it/pairing_check.py');
      if (py == null ||
          !script.existsSync() ||
          Process.runSync(py, [
                '-c',
                'import kestrel_bridge.devices',
              ], workingDirectory: '../bridge').exitCode !=
              0) {
        markTestSkipped('python with the bridge is not available');
        return;
      }
      String run(List<String> a) {
        final r = Process.runSync(py, [script.path, ...a]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        return (r.stdout as String).trim();
      }

      // the bridge's encoder produces our bytes
      final qr = run([
        'encode',
        toHex(pub),
        payload.name,
        payload.platform,
        toHex(nonce),
        '${payload.ts}',
      ]);
      expect(qr, encodePairingQr(payload));
      // the bridge's signature message for our QR equals ours
      final approver = 'ab' * 16;
      final d = decodePairingQr(qr);
      expect(
        run(['sign', qr, approver]),
        toHex(pairingSignMessage(d.raw, approver)),
      );
      // the bridge parses what we encode
      final parsed = json.decode(run(['parse', qr])) as Map<String, Object?>;
      expect(parsed['pubkey'], toHex(pub));
      expect(parsed['name'], 'Моя Pixel');
      expect(parsed['platform'], 'android');
      expect(parsed['nonce'], toHex(nonce));
    });
  });

  group('LXMF command envelope (3)', () {
    test('command body and fields', () {
      final body = encodeLxmfCommand(
        cmdId: 'k0123456789ab',
        ts: 1700000000.5,
        path: '/send_lxmf',
        args: {'cmd_id': 'k0123456789ab', 'to': '11' * 16, 'text': 'hi'},
      );
      final m = asMap(unpackb(body));
      expect(m['v'], 2);
      expect(m['cmd_id'], 'k0123456789ab');
      expect(m['ts'], 1700000000.5);
      expect(m['path'], '/send_lxmf');
      expect(asMap(m['args'])['text'], 'hi');
      final f = lxmfCommandFields(body);
      expect(f[0xFB], utf8.encode('kestrel.cmd')); // FIELD_CUSTOM_TYPE
      expect(f[0xFC], body); // FIELD_CUSTOM_DATA
    });

    test('responses and pushes are recognised, others are not', () {
      final resp = decodeLxmfEnvelope({
        0xFB: Uint8List.fromList(utf8.encode('kestrel.resp')),
        0xFC: packb({
          'v': 2,
          'cmd_id': 'k1',
          'ok': true,
          'result': {'x': 1},
        }),
      })!;
      expect(resp.isResponse, isTrue);
      expect(BridgeConnection.parseResponse(resp.payload), {'x': 1});
      final push = decodeLxmfEnvelope({
        0xFB: Uint8List.fromList(utf8.encode('kestrel.push')),
        0xFC: packb({
          't': 'push',
          'seq': 1,
          'id': 'ab' * 8,
          'ts': 1.0,
          'event': 'lxmf.message',
          'data': {
            'peer': 'x',
            'hash': 'y',
            'incoming': true,
            'ts': 1.0,
            'text': 'hi',
          },
        }),
      })!;
      expect(push.isPush, isTrue);
      expect(PushEvent.tryParse(push.payload)!.event, 'lxmf.message');
      expect(decodeLxmfEnvelope({}), isNull);
      expect(
        decodeLxmfEnvelope({
          0xFB: Uint8List.fromList(utf8.encode('other')),
          0xFC: packb({}),
        }),
        isNull,
      );
    });

    test('Link-only paths are never sent over LXMF', () {
      for (final p in [
        '/subscribe',
        '/devices/list',
        '/devices/approve',
        '/vault/put',
      ]) {
        expect(BridgeConnection.lxmfAllowed(p), isFalse, reason: p);
      }
      for (final p in [
        '/hello',
        '/sync_chats',
        '/get_messages',
        '/list_rooms',
        '/get_room_messages',
        '/send_lxmf',
        '/send_rrc',
        '/mark_read',
      ]) {
        expect(BridgeConnection.lxmfAllowed(p), isTrue, reason: p);
      }
    });
  });
}
