@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/bridge/bridge_connection.dart';
import 'package:kestrel/bridge/bridge_service.dart';
import 'package:kestrel/bridge/codec.dart';
import 'package:kestrel/node/identity_store.dart';
import 'package:kestrel/node/node_service.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/bridge_env.dart';

/// Two Dart devices against the real Python bridge (with the fake MeshChatX)
/// over a real Reticulum transport node on loopback: connect, identify,
/// hello, sync, send as A, push, QR pairing of the second device, origin
/// device, revoke.
class Dev {
  Dev._(
    this.secrets,
    this.identity,
    this.adb,
    this.repo,
    this.node,
    this.bridge,
  );

  final MemorySecretStore secrets;
  final Identity identity;
  final AppDatabase adb;
  final Repo repo;
  final NodeService node;
  final BridgeService bridge;

  String get id => toHex(identity.hash);

  static Future<(MemorySecretStore, Identity)> newIdentity() async {
    final s = MemorySecretStore();
    return (s, await IdentityStore(s).loadOrCreate());
  }

  static Future<Dev> start(
    MemorySecretStore secrets,
    Identity identity,
    int port, {
    String deviceName = 'Dart device',
    String? dbPath,
  }) async {
    // devices 1 and 2 share the in-memory database; a path gives a device its
    // own storage
    final adb = await AppDatabase.open(
      dbPath ?? inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    final repo = Repo(adb);
    await repo.setSetting(SettingKeys.serverHost, '127.0.0.1');
    await repo.setSetting(SettingKeys.serverPort, '$port');
    await repo.setSetting(SettingKeys.deviceName, deviceName);
    final node = NodeService(
      repo: repo,
      secrets: secrets,
      transportConfig: const TransportConfig(
        stampAnnounces: false,
        stampPathRequests: false,
      ),
      routerConfig: const LxmRouterConfig(
        processInterval: Duration(milliseconds: 200),
      ),
    );
    await node.start();
    late BridgeService bridge;
    bridge = BridgeService(
      repo: repo,
      ownDeviceId: () => toHex(node.identity.hash),
      identity: () => node.identity,
      sendAsB: node.sendMessage,
      retryResend: const Duration(seconds: 2),
      apiFactory: (key, allow) => BridgeConnection(
        rns: node.rns,
        identity: node.identity,
        bridgePublicKey: key,
        router: node.router,
        allowFallback: allow,
        retryMax: const Duration(seconds: 4),
        rejectedRetry: const Duration(seconds: 4),
        pathTimeout: const Duration(seconds: 8),
      ),
    );
    node.bridge = bridge;
    return Dev._(secrets, identity, adb, repo, node, bridge);
  }

  Future<void> stop() async {
    await bridge.stop();
    await node.stop();
    await adb.close();
  }
}

Future<void> waitFor(
  Future<bool> Function() cond, {
  String what = 'condition',
  Duration timeout = const Duration(seconds: 150),
}) async {
  final end = DateTime.now().add(timeout);
  while (!await cond()) {
    if (DateTime.now().isAfter(end)) throw StateError('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
}

void main() {
  if (!BridgeEnv.available) {
    test(
      'bridge environment not available',
      () {},
      skip:
          'needs tools/.venv with the bridge installed (pip install -e bridge)',
    );
    return;
  }
  setUpAll(sqfliteFfiInit);

  test(
    'Dart devices against the Python bridge: sync, send, push, pair, revoke',
    () async {
      final (s1, id1) = await Dev.newIdentity();
      final env = await BridgeEnv.start(toHex(id1.publicKey));
      addTearDown(env.stop);
      final d1 = await Dev.start(s1, id1, env.tcpPort, deviceName: 'Dart one');
      addTearDown(d1.stop);

      // connect + identify + hello + subscribe, then sync into account A
      await d1.bridge.configure(
        'bridge public key (hex):   ${env.bridgePub}\n',
      );
      final log = <String>[];
      final sub = d1.bridge.statusChanges.listen(
        (s) => log.add('${DateTime.now().second}:${s.state.name}/${s.detail}'),
      );
      addTearDown(sub.cancel);
      await waitFor(
        () async => d1.bridge.status.state == BridgeState.connected,
        what: 'device 1 connected ($log)',
      );
      final hello = d1.bridge.status.hello!;
      expect(hello.protocolVersion, 2);
      expect(hello.device.deviceId, d1.id);
      expect(hello.device.bootstrap, isTrue);

      Future<int?> chatOf(Dev d) => d.bridge.store.chatIdForPeer(env.peer);
      await waitFor(
        () async => await chatOf(d1) != null,
        what: 'chat synced',
        timeout: const Duration(seconds: 30),
      );
      final chat1 = (await chatOf(d1))!;
      await waitFor(
        () async => (await d1.repo.messages(chat1)).isNotEmpty,
        what: 'messages synced',
      );
      final first = (await d1.repo.messages(chat1)).first;
      expect(first.text, 'earlier message');
      expect(first.senderIdentity, 'A');
      expect(first.originDevice, isNull); // typed in MeshChatX
      expect((await d1.repo.chat(chat1))!.unread, 1);
      expect((await d1.bridge.store.cursor()), greaterThan(0));

      // opening the chat marks it read on the bridge
      await d1.bridge.markRead(chat1);
      expect((await d1.repo.chat(chat1))!.unread, 0);

      // send as A through the bridge
      final mid = await d1.node.sendMessage(chat1, 'from dart');
      await waitFor(
        () async => (await d1.repo.message(mid))!.lxmfHash != null,
        what: 'bridge ack',
      );
      final sent = (await d1.repo.message(mid))!;
      expect((sent.senderIdentity, sent.originDevice), ('A', d1.id));
      expect(
        (await d1.repo.log(mid)).map((l) => l.stage),
        containsAllInOrder(['queued', 'sent_to_bridge', 'bridge_accepted']),
      );
      expect(((await env.calls())['sent']! as List).length, 1);

      // push from the "network"
      await env.emitMessage('pushed hello');
      await waitFor(
        () async =>
            (await d1.repo.messages(chat1))
                .any((m) => m.text == 'pushed hello' && m.direction == 'in'),
        what: 'push received',
      );

      // pair a second device through the QR payload
      final (s2, id2) = await Dev.newIdentity();
      final d2 = await Dev.start(s2, id2, env.tcpPort, deviceName: 'Dart two');
      addTearDown(d2.stop);
      await d2.bridge.configure(env.bridgePub);
      await d2.bridge.beginPairing();
      // the bridge tells the unknown key why: waiting for approval
      await waitFor(
        () async =>
            d2.bridge.status.state == BridgeState.awaitingApproval &&
            d2.bridge.status.detail == 'unauthorized',
        what: 'device 2 waiting for approval (kestrel.reject)',
      );
      final qr = encodePairingQr(await d2.bridge.newPairingPayload());
      final decoded = decodePairingQr(qr);
      expect(decoded.payload.deviceId, d2.id);
      final rec = await d1.bridge.approveDevice(
        decoded,
        name: 'Second device',
        field: true,
      );
      expect((rec.deviceId, rec.isField, rec.bootstrap), (d2.id, true, false));
      await waitFor(
        () async => d2.bridge.status.state == BridgeState.connected,
        what: 'device 2 connected after approval',
      );
      d2.bridge.endPairing();

      // device 2 sees what device 1 sent, attributed to device 1
      await waitFor(
        () async => await chatOf(d2) != null,
        what: 'chat on device 2',
        timeout: const Duration(seconds: 30),
      );
      final chat2 = (await chatOf(d2))!;
      await waitFor(
        () async =>
            (await d2.repo.messages(chat2)).any((m) => m.text == 'from dart'),
        what: 'device 2 sync',
      );
      final seen = (await d2.repo.messages(chat2))
          .firstWhere((m) => m.text == 'from dart');
      expect((seen.originDevice, seen.cmdId != null), (d1.id, true));
      final names = {
        for (final d in await d2.bridge.store.devices()) d.deviceId: d.name,
      };
      expect(names[d1.id], 'Dart one');
      // the app owns the device name: device 2's own /hello replaced the
      // proposed name that the approver used
      expect(names[d2.id], 'Dart two');

      // invite pairing: device 1 shows an invite QR, a brand new device 3
      // joins from it alone (no bridge address typed)
      final invite = await d1.bridge.createInvite();
      expect(invite.text, startsWith('kestrel-invite:v1:'));
      final tmp = Directory.systemTemp.createTempSync('kestrel-dart-it');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final (s3, id3) = await Dev.newIdentity();
      final d3 = await Dev.start(
        s3,
        id3,
        env.tcpPort,
        deviceName: 'Dart three',
        dbPath: '${tmp.path}/d3.db',
      );
      addTearDown(d3.stop);
      expect(await d3.bridge.configuredKey(), isNull);
      final rec3 = await d3.bridge.redeemInvite(invite.text);
      expect(
        (rec3.deviceId, rec3.addedBy, rec3.name),
        (d3.id, d1.id, 'Dart three'),
      );
      await waitFor(
        () async => d3.bridge.status.state == BridgeState.connected,
        what: 'device 3 connected on the redeemed link',
      );
      expect(await d3.bridge.configuredKey(), env.bridgePub);
      // the same invite cannot be used twice
      final (s4, id4) = await Dev.newIdentity();
      final d4 = await Dev.start(
        s4,
        id4,
        env.tcpPort,
        dbPath: '${tmp.path}/d4.db',
      );
      addTearDown(d4.stop);
      await expectLater(
        d4.bridge.redeemInvite(invite.text),
        throwsA(
          isA<BridgeError>().having((e) => e.code, 'code', 'pairing_replay'),
        ),
      );
      expect(await d4.bridge.configuredKey(), isNull);
      // one device name: renaming in settings renames it on the bridge
      await d3.bridge.setDeviceName('Dart three renamed');
      await waitFor(
        () async => (await d1.bridge.refreshDevices()).any(
          (d) => d.deviceId == d3.id && d.name == 'Dart three renamed',
        ),
        what: 'device 3 rename visible on device 1',
      );
      await d3.bridge.stop();

      // revoke device 2 from device 1: its Link closes, it stays out
      await d1.bridge.revokeDevice(d2.id, reason: 'integration test');
      // ... and is told why: kestrel.reject device_revoked -> revoked state
      await waitFor(
        () async => d2.bridge.status.state == BridgeState.revoked,
        what: 'device 2 sees the revoked state',
        timeout: const Duration(seconds: 30),
      );
      final list = await d1.bridge.refreshDevices();
      expect(list.firstWhere((d) => d.deviceId == d2.id).isRevoked, isTrue);
      await Future<void>.delayed(const Duration(seconds: 8));
      expect(d2.bridge.status.state, isNot(BridgeState.connected));
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
