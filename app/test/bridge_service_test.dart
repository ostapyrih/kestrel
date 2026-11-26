import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/bridge/bridge_connection.dart';
import 'package:kestrel/bridge/bridge_service.dart';
import 'package:kestrel/bridge/codec.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_bridge_api.dart';

final me = '0a' * 16;
final peer = '11' * 16;

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase adb;
  late Repo repo;
  late FakeBridgeApi api;
  late BridgeService svc;
  late Identity identity;
  final sentAsB = <(int, String)>[];

  BridgeService makeService() => BridgeService(
    repo: repo,
    ownDeviceId: () => me,
    identity: () => identity,
    apiFactory: (_, _) => api,
    retryResend: const Duration(milliseconds: 50),
    sendAsB: (chatId, text) async {
      sentAsB.add((chatId, text));
      final ids = await repo.insertOutgoing(
        identity: 'B',
        chatId: chatId,
        destinationHash: peer,
        text: text,
        route: 'opportunistic',
        transport: 'tcp',
      );
      return ids.messageId;
    },
  );

  Future<void> up({String stateId = 'state1'}) async {
    api.connect(helloFor(me, stateId: stateId));
    await svc.flushEvents();
  }

  void defaultHandlers({List<Map<String, Object?>>? convs}) {
    api.handlers['/sync_chats'] = (a) => {
      'state_id': 'state1',
      'cursor': 7,
      'reset': false,
      'more': false,
      'lxmf': convs ?? [convMap(peer, unread: true, lastId: 2)],
      'rrc': [],
    };
    api.handlers['/get_messages'] = (a) => {
      'peer': peer,
      'has_more': false,
      'gap': false,
      'messages': [
        msgMap(1, 'a1' * 16, text: 'earlier'),
        msgMap(
          2,
          'a2' * 16,
          incoming: false,
          text: 'from iphone',
          origin: 'd1' * 16,
          cmdId: 'cmd-from-iphone',
        ),
        msgMap(3, 'a3' * 16, incoming: false, text: 'typed in web'),
      ],
    };
    api.handlers['/devices/list'] = (a) => {
      'devices': [deviceMap(me, name: 'This', bootstrap: true)],
      'key_epoch': 1,
    };
    api.handlers['/list_rooms'] = (a) => {'hubs': []};
    api.handlers['/mark_read'] = (a) => {'peer': a['peer'], 'cursor': 8};
  }

  setUp(() async {
    adb = await AppDatabase.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    repo = Repo(adb);
    api = FakeBridgeApi();
    identity = await Identity.generate();
    sentAsB.clear();
    svc = makeService();
    defaultHandlers();
    await svc.configure('bridge public key: ${'cd' * 64}');
  });

  tearDown(() async {
    await svc.stop();
    await adb.close();
  });

  group('sync into account A', () {
    test('conversations, messages, origin device, cursor persisted', () async {
      await up();
      final chat = (await svc.store.chatIdForPeer(peer))!;
      final msgs = await repo.messages(chat);
      expect(msgs.map((m) => m.text), [
        'earlier',
        'from iphone',
        'typed in web',
      ]);
      expect(msgs.every((m) => m.senderIdentity == 'A'), isTrue);
      expect(msgs[0].originDevice, isNull);
      expect(msgs[1].originDevice, 'd1' * 16);
      expect(msgs[1].cmdId, 'cmd-from-iphone');
      expect(msgs[1].direction, 'out');
      expect(msgs[2].originDevice, isNull); // typed in MeshChatX
      expect((await repo.chat(chat))!.unread, 1);
      expect((await repo.chat(chat))!.bridgeLastId, 3);
      expect(await svc.store.cursor(), 7);
      expect(await svc.store.stateId(), 'state1');
      // a new chat starts with a tail fetch (no cursor)
      expect(
        api.callsTo('/get_messages').first.containsKey('after_id'),
        isFalse,
      );
    });

    test('a restarted service resumes from the stored cursor', () async {
      await up();
      await svc.stop();
      api = FakeBridgeApi();
      defaultHandlers(convs: const []);
      svc = makeService();
      await svc.configure('cd' * 64);
      await up();
      final sync = api.callsTo('/sync_chats').single;
      expect(sync['cursor'], 7);
      expect(sync['state_id'], 'state1');
    });

    test('catch-up uses after_id = stored last id', () async {
      await up();
      api.calls.clear();
      api.handlers['/sync_chats'] = (a) => {
        'state_id': 'state1',
        'cursor': 9,
        'reset': false,
        'more': false,
        'lxmf': [convMap(peer, lastId: 4)],
        'rrc': [],
      };
      api.handlers['/get_messages'] = (a) => {
        'peer': peer,
        'has_more': false,
        'gap': false,
        'messages': [msgMap(4, 'a4' * 16, text: 'new one')],
      };
      api.connect(helloFor(me));
      await svc.flushEvents();
      final get = api.callsTo('/get_messages').first;
      expect(get['after_id'], 3);
      final chat = (await svc.store.chatIdForPeer(peer))!;
      expect((await repo.messages(chat)).length, 4);
      expect(await svc.store.cursor(), 9);
    });

    test('a changed state_id resets cursors but keeps the data', () async {
      await up();
      final chat = (await svc.store.chatIdForPeer(peer))!;
      api.calls.clear();
      await up(stateId: 'other-db');
      final sync = api.callsTo('/sync_chats').first;
      expect(sync['cursor'], 0);
      expect(sync.containsKey('state_id'), isFalse);
      expect((await repo.messages(chat)).length, 3); // nothing deleted
    });

    test('open outgoing messages refetch the conversation tail', () async {
      await up();
      final chat = (await svc.store.chatIdForPeer(peer))!;
      // an outgoing message sent from this device, not yet delivered
      await svc.store.upsertMessage(
        chat,
        BridgeMessage.fromMap(
          msgMap(5, 'a5' * 16, incoming: false, state: 'sent', text: 'pending'),
        ),
      );
      api.calls.clear();
      api.handlers['/sync_chats'] = (a) => {
        'state_id': 'state1',
        'cursor': 10,
        'reset': false,
        'more': false,
        'lxmf': [convMap(peer, lastId: 5)],
        'rrc': [],
      };
      api.handlers['/get_messages'] = (a) => {
        'peer': peer,
        'has_more': false,
        'gap': false,
        // nothing is newer than id 5; only the state of message 5 changed
        'messages': a.containsKey('after_id')
            ? []
            : [
                msgMap(
                  5,
                  'a5' * 16,
                  incoming: false,
                  state: 'delivered',
                  text: 'pending',
                ),
              ],
      };
      await svc.resync();
      final gets = api.callsTo('/get_messages');
      expect(gets.length, 2);
      expect(gets[0]['after_id'], 5);
      expect(gets[1].containsKey('after_id'), isFalse); // tail refetch
      final m = (await repo.messages(chat))
          .firstWhere((m) => m.text == 'pending');
      expect(m.status, MsgStatus.delivered);
    });
  });

  group('push', () {
    test('events are deduplicated by id and by message hash', () async {
      await up();
      final chat = (await svc.store.chatIdForPeer(peer))!;
      final data = {
        'peer': peer,
        'hash': 'b1' * 16,
        'incoming': true,
        'state': 'delivered',
        'method': 'direct',
        'title': '',
        'text': 'pushed',
        'ts': 1700000100.0,
        'name': 'Peer',
        'origin_device': null,
        'cmd_id': null,
      };
      api.push('lxmf.message', data, id: 'evt-1');
      api.push('lxmf.message', data, id: 'evt-1'); // same event twice
      api.push('lxmf.message', data, id: 'evt-2'); // same message again
      await svc.flushEvents();
      final n = (await repo.messages(chat)).where((m) => m.text == 'pushed');
      expect(n.length, 1);
    });

    test('lxmf.state updates status and the delivery log', () async {
      await up();
      final chat = (await svc.store.chatIdForPeer(peer))!;
      await svc.store.upsertMessage(
        chat,
        BridgeMessage.fromMap(
          msgMap(6, 'c1' * 16, incoming: false, state: 'sending', text: 'x'),
        ),
      );
      final id = (await repo.messages(chat)).last.id;
      api.push('lxmf.state', {'hash': 'c1' * 16, 'state': 'delivered'});
      await svc.flushEvents();
      expect((await repo.message(id))!.status, MsgStatus.delivered);
      expect((await repo.log(id)).map((l) => l.stage), contains('delivered'));
    });

    test('read_state clears the unread flag', () async {
      await up();
      final chat = (await svc.store.chatIdForPeer(peer))!;
      expect((await repo.chat(chat))!.unread, 1);
      api.push('read_state', {
        'peer': peer,
        'unread': false,
        'cursor': 11,
        'by_device': null,
      });
      await svc.flushEvents();
      expect((await repo.chat(chat))!.unread, 0);
    });

    test('opening a chat sends /mark_read once', () async {
      await up();
      final chat = (await svc.store.chatIdForPeer(peer))!;
      await svc.markRead(chat);
      await svc.markRead(chat);
      expect(api.callsTo('/mark_read').length, 1);
      expect((await repo.chat(chat))!.unread, 0);
    });
  });

  group('sending as A', () {
    test('the outbox freezes sender A and route via_bridge', () async {
      await up();
      final chat = (await svc.store.chatIdForPeer(peer))!;
      api.handlers['/send_lxmf'] = (a) => {
        'lxmf_hash': 'f1' * 16,
        'state': 'outbound',
        'method': 'direct',
        'to': a['to'],
        'ts': 1.0,
      };
      final mid = await svc.sendMessage(chat, 'hello');
      final oid = (await svc.store.outboxIdForMessage(mid))!;
      final ob = (await repo.outbox(oid))!;
      expect((ob.sender, ob.route), ('A', 'via_bridge'));
      // nobody may change it afterwards
      await expectLater(
        adb.db.update(
          'outbox',
          {'sender_identity': 'B'},
          where: 'id = ?',
          whereArgs: [oid],
        ),
        throwsA(anything),
      );
      await expectLater(
        adb.db.update(
          'outbox',
          {'route': 'direct'},
          where: 'id = ?',
          whereArgs: [oid],
        ),
        throwsA(anything),
      );
      await svc.flushEvents();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sent = api.callsTo('/send_lxmf').single;
      expect(sent['to'], peer);
      expect(sent['text'], 'hello');
      expect(cmdIdRe.hasMatch(sent['cmd_id']! as String), isTrue);
      final m = (await repo.message(mid))!;
      expect(m.lxmfHash, 'f1' * 16);
      expect((m.senderIdentity, m.route, m.originDevice), ('A', 'direct', me));
      expect(
        (await repo.log(mid)).map((l) => l.stage),
        containsAllInOrder(['queued', 'sent_to_bridge', 'bridge_accepted']),
      );
    });

    test(
      'unreachable bridge: the message stays queued, then goes out',
      () async {
        final chat = await svc.store.ensureChat(peer, name: 'Peer');
        api.handlers['/send_lxmf'] = (a) => {
          'lxmf_hash': 'f2' * 16,
          'state': 'sent',
          'method': 'opportunistic',
          'to': peer,
          'ts': 1.0,
        };
        final mid = await svc.sendMessage(chat, 'later');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        var m = (await repo.message(mid))!;
        expect(m.status, MsgStatus.queued);
        expect(m.lxmfHash, isNull);
        expect(
          (await repo.log(mid)).map((l) => l.stage),
          contains('bridge_unreachable'),
        );
        expect(api.callsTo('/send_lxmf'), isEmpty);
        await up(); // the bridge comes back: the queue is flushed
        await Future<void>.delayed(const Duration(milliseconds: 100));
        m = (await repo.message(mid))!;
        expect(m.lxmfHash, 'f2' * 16);
        expect(m.status, MsgStatus.sent);
        expect(m.route, 'opportunistic');
      },
    );

    test('a replay answer with a cached success counts as accepted', () async {
      await up();
      final chat = (await svc.store.chatIdForPeer(peer))!;
      api.handlers['/send_lxmf'] = (a) => throw BridgeError('replay', 'used', {
        'cached': {
          'ok': true,
          'result': {
            'lxmf_hash': 'f3' * 16,
            'state': 'outbound',
            'method': 'direct',
          },
        },
      });
      final mid = await svc.sendMessage(chat, 'again');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect((await repo.message(mid))!.lxmfHash, 'f3' * 16);
    });

    test('upstream_unavailable keeps the message queued and retries', () async {
      await up();
      final chat = (await svc.store.chatIdForPeer(peer))!;
      var n = 0;
      api.handlers['/send_lxmf'] = (a) {
        if (++n == 1) throw BridgeError('upstream_unavailable');
        return {
          'lxmf_hash': 'f4' * 16,
          'state': 'outbound',
          'method': 'direct',
        };
      };
      final mid = await svc.sendMessage(chat, 'retry me');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await repo.message(mid))!.status, MsgStatus.queued);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect((await repo.message(mid))!.lxmfHash, 'f4' * 16);
      expect(n, 2);
    });

    test('send_failed is final', () async {
      await up();
      final chat = (await svc.store.chatIdForPeer(peer))!;
      api.handlers['/send_lxmf'] = (a) => throw BridgeError('send_failed');
      final mid = await svc.sendMessage(chat, 'nope');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final m = (await repo.message(mid))!;
      expect((m.status, m.error), (MsgStatus.failed, 'send_failed'));
    });

    test(
      '"send from B instead" creates a NEW B message, A stays cancelled',
      () async {
        final chat = await svc.store.ensureChat(peer, name: 'Peer');
        final mid = await svc.sendMessage(chat, 'stuck');
        final newId = await svc.sendFromBInstead(mid);
        expect(newId, isNotNull);
        expect(newId, isNot(mid));
        // the A message is cancelled and still sender A
        final a = (await repo.message(mid))!;
        expect(
          (a.status, a.senderIdentity, a.route),
          (MsgStatus.cancelled, 'A', 'via_bridge'),
        );
        final ob = (await repo.outbox(
          (await svc.store.outboxIdForMessage(mid))!,
        ))!;
        expect((ob.sender, ob.route), ('A', 'via_bridge'));
        expect((await svc.store.queuedSends()), isEmpty);
        // a separate B message in the B chat to the same peer
        final b = (await repo.message(newId!))!;
        expect((b.senderIdentity, b.text, b.direction), ('B', 'stuck', 'out'));
        final bChat = (await repo.chat(b.chatId))!;
        expect((bChat.accountIdentity, bChat.peerHash), ('B', peer));
        expect(sentAsB, [(bChat.id, 'stuck')]);
        // the A message never leaves later
        await up();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(api.callsTo('/send_lxmf'), isEmpty);
      },
    );

    test(
      'cancel works while queued, not after the bridge accepted it',
      () async {
        final chat = await svc.store.ensureChat(peer, name: 'Peer');
        final m1 = await svc.sendMessage(chat, 'cancel me');
        expect(await svc.cancelQueued(m1), isTrue);
        expect((await repo.message(m1))!.status, MsgStatus.cancelled);
        api.handlers['/send_lxmf'] = (a) => {
          'lxmf_hash': 'f5' * 16,
          'state': 'outbound',
          'method': 'direct',
        };
        await up();
        final m2 = await svc.sendMessage(chat, 'accepted');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(await svc.cancelQueued(m2), isFalse);
        expect(await svc.sendFromBInstead(m2), isNull);
        expect(sentAsB, isEmpty);
      },
    );

    test(
      'a bridge that is switched off keeps the queue (no data loss)',
      () async {
        final chat = await svc.store.ensureChat(peer, name: 'Peer');
        final mid = await svc.sendMessage(chat, 'while off');
        await svc.setEnabled(false);
        expect(await repo.bridgeEnabled(), isFalse);
        expect((await repo.message(mid))!.status, MsgStatus.queued);
        expect((await svc.store.queuedSends()).single.messageId, mid);
        expect((await repo.chats()).length, 1);
      },
    );
  });

  group('devices', () {
    test(
      'revoked push for this device stops the bridge and keeps data',
      () async {
        await up();
        final chat = (await svc.store.chatIdForPeer(peer))!;
        api.push('device_revoked', {
          'device_id': me,
          'revoked_at': 1.0,
          'key_epoch': 2,
        });
        await svc.flushEvents();
        expect(svc.status.state, BridgeState.revoked);
        expect(api.revokedMarked, isTrue);
        expect(await svc.isRevoked(), isTrue);
        expect(await svc.configuredKey(), isNull);
        expect((await repo.messages(chat)).length, 3);
      },
    );

    test(
      'revoking while the vault is in use is blocked with a clear error',
      () async {
        api.connect(helloFor(me, vaultInUse: true));
        await svc.flushEvents();
        await expectLater(
          svc.revokeDevice('d1' * 16),
          throwsA(isA<VaultKeysUnsupported>()),
        );
        expect(api.callsTo('/devices/revoke'), isEmpty);
      },
    );

    test('revoke, rename and role calls follow the spec', () async {
      await up();
      api.handlers['/devices/revoke'] = (a) => {
        'device': deviceMap('d1' * 16, revokedAt: 5),
        'key_epoch': 2,
      };
      api.handlers['/devices/rename'] = (a) => {
        'device': deviceMap('d1' * 16, name: a['name']! as String),
      };
      api.handlers['/devices/set_role'] = (a) => {
        'device': deviceMap(
          'd1' * 16,
          roles: [if (a['enabled'] == true) 'field'],
        ),
      };
      await svc.renameDevice('d1' * 16, 'Tablet');
      await svc.setFieldRole('d1' * 16, true);
      await svc.revokeDevice('d1' * 16, reason: 'lost');
      expect(api.callsTo('/devices/rename').single, {
        'device_id': 'd1' * 16,
        'name': 'Tablet',
      });
      expect(api.callsTo('/devices/set_role').single['role'], 'field');
      expect(api.callsTo('/devices/revoke').single['reason'], 'lost');
      final d = (await svc.store.devices()).firstWhere(
        (d) => d.deviceId == 'd1' * 16,
      );
      expect(d.isRevoked, isTrue);
    });

    test(
      'approve signs the domain-separated payload and sends bin fields',
      () async {
        await up();
        final newId = await Identity.generate();
        final p = PairingPayload(
          pubkey: newId.publicKey,
          name: 'Tablet',
          platform: 'android',
          nonce: Uint8List.fromList(List.filled(16, 3)),
          ts: 1700000000.5,
        );
        final decoded = decodePairingQr(encodePairingQr(p));
        api.handlers['/devices/approve'] = (a) => {
          'device': deviceMap(p.deviceId, name: 'Tablet', roles: ['field']),
        };
        await svc.approveDevice(decoded, field: true);
        final req = api.callsTo('/devices/approve').single;
        expect(req['payload'], decoded.raw);
        expect(req['roles'], ['field']);
        final sig = req['signature']! as Uint8List;
        final signer = Identity.fromPublicKey(identity.publicKey);
        expect(
          await signer.validate(sig, pairingSignMessage(decoded.raw, me)),
          isTrue,
        );
        // not valid for another approver id (domain/approver binding)
        expect(
          await signer.validate(
            sig,
            pairingSignMessage(decoded.raw, 'bb' * 16),
          ),
          isFalse,
        );
      },
    );

    test('approving while the vault is in use is blocked', () async {
      api.connect(helloFor(me, vaultInUse: true));
      await svc.flushEvents();
      final p = PairingPayload(
        pubkey: Uint8List(64),
        name: 'x',
        platform: 'linux',
        nonce: Uint8List(16),
        ts: 1,
      );
      await expectLater(
        svc.approveDevice(decodePairingQr(encodePairingQr(p))),
        throwsA(isA<VaultKeysUnsupported>()),
      );
    });
  });

  group('RRC', () {
    test(
      'messages starting with / are blocked before anything is sent',
      () async {
        await up();
        await expectLater(
          svc.sendRrc('ee' * 16, 'general', '/join #evil'),
          throwsA(isA<RrcCommandBlocked>()),
        );
        await expectLater(
          svc.sendRrc('ee' * 16, 'general', '   /nick x'),
          throwsA(isA<RrcCommandBlocked>()),
        );
        expect(api.callsTo('/send_rrc'), isEmpty);
        api.handlers['/send_rrc'] = (a) => {'sent': true};
        await svc.sendRrc('ee' * 16, 'general', 'hello / not a command');
        expect(
          api.callsTo('/send_rrc').single['text'],
          'hello / not a command',
        );
      },
    );

    test('rooms and room messages are stored under account A', () async {
      await up();
      api.handlers['/list_rooms'] = (a) => {
        'hubs': [
          {
            'hub': 'ee' * 16,
            'name': 'Hub',
            'connected': true,
            'status': 'ok',
            'rooms': [
              {'room': 'general', 'unread': 3, 'mention': true},
            ],
          },
        ],
      };
      await svc.refreshRooms();
      final rooms = await svc.store.rooms();
      expect(
        (rooms.single.room, rooms.single.unread, rooms.single.mention),
        ('general', 3, true),
      );
      api.handlers['/get_room_messages'] = (a) => {
        'hub': a['hub'],
        'room': a['room'],
        'has_more': false,
        'gap': false,
        'messages': [
          {
            'seq': 1,
            'kind': 'msg',
            'nick': 'ann',
            'text': 'hi',
            'ts': 1700000000000,
            'mention': false,
            'src': 'x',
          },
          {
            'seq': 2,
            'kind': 'msg',
            'nick': 'bob',
            'text': 'yo',
            'ts': 1700000001000,
            'mention': true,
            'src': 'y',
          },
        ],
      };
      await svc.loadRoom('ee' * 16, 'general');
      final msgs = await svc.store.rrcMessages('ee' * 16, 'general');
      expect(msgs.map((m) => m.text), ['hi', 'yo']);
      expect((await svc.store.rooms()).single.unread, 0);
      // push adds one and bumps the counter
      api.push('rrc.message', {
        'hub': 'ee' * 16,
        'room': 'general',
        'seq': 3,
        'kind': 'msg',
        'nick': 'cy',
        'text': 'new',
        'ts': 1700000002000,
        'mention': false,
        'src': 'z',
      });
      await svc.flushEvents();
      expect((await svc.store.rrcMessages('ee' * 16, 'general')).length, 3);
      expect((await svc.store.rooms()).single.unread, 1);
    });
  });

  group('pairing on the new device', () {
    test(
      'beginPairing switches to fast retries; the payload is fresh',
      () async {
        await svc.beginPairing();
        expect(api.fastRetry, isTrue);
        expect(api.retries, 1);
        final a = await svc.newPairingPayload();
        final b = await svc.newPairingPayload();
        expect(a.pubkey, identity.publicKey);
        expect(a.nonce, isNot(b.nonce));
        expect(a.platform, matches(RegExp(r'^[a-z0-9][a-z0-9._-]{0,31}$')));
        svc.endPairing();
        expect(api.fastRetry, isFalse);
      },
    );
  });
}
