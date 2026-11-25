@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/node/identity_store.dart';
import 'package:kestrel/node/node_service.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/python_peer.dart';

/// NodeService end to end against the Python LXMF reference
/// (`tools/it/lxmf_peer.py`) over a real TCP connection on loopback.
void main() {
  if (findPython() == null) {
    test('python reference not available', () {}, skip: 'no tools/.venv');
    return;
  }
  setUpAll(sqfliteFfiInit);

  late LxmfPeer peer;
  late AppDatabase adb;
  late Repo repo;
  late NodeService node;

  setUp(() async {
    peer = await LxmfPeer.start(name: 'Python Peer');
    adb = await AppDatabase.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    repo = Repo(adb);
    await repo.setSetting(SettingKeys.serverHost, '127.0.0.1');
    await repo.setSetting(SettingKeys.serverPort, '${peer.port}');
    await repo.setSetting(SettingKeys.displayName, 'Kestrel Test');
    node = NodeService(
      repo: repo,
      secrets: MemorySecretStore(),
      transportConfig: const TransportConfig(
        stampAnnounces: false,
        stampPathRequests: false,
      ),
      routerConfig: const LxmRouterConfig(
        processInterval: Duration(milliseconds: 200),
        deliveryRetryWait: Duration(seconds: 3),
        pathRequestWait: Duration(seconds: 2),
      ),
    );
    await node.start();
  });

  tearDown(() async {
    await node.stop();
    await peer.stop();
    await adb.close();
  });

  Future<void> waitFor(Future<bool> Function() cond) async {
    final end = DateTime.now().add(const Duration(seconds: 40));
    while (!await cond()) {
      if (DateTime.now().isAfter(end)) throw StateError('condition not met');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  test('connects over TCP, exchanges messages both ways with Python', () async {
    await waitFor(() async => node.connection == NodeConnection.online);

    // Python learns our address from our announce, we learn theirs.
    peer.send({'cmd': 'announce'});
    await waitFor(() async => (await repo.peers()).isNotEmpty);
    expect((await repo.peers()).first.displayName, 'Python Peer');
    await peer.waitFor(
      'announce_received',
      where: (m) => m['dest_hash'] == node.addressHex,
    );

    // Dart -> Python
    final chat = await node.openChat(peer.destHash, name: 'Python Peer');
    final mid = await node.sendMessage(chat, 'hello from the app');
    final r = await peer.waitFor('received');
    expect(r['content'], 'hello from the app');
    expect(r['source'], node.addressHex);
    expect(r['signature_validated'], isTrue);
    await waitFor(
      () async => (await repo.message(mid))!.status == MsgStatus.delivered,
    );
    final m = (await repo.message(mid))!;
    expect((m.route, m.transport, m.senderIdentity), (
      'opportunistic',
      'tcp',
      'B',
    ));
    expect(
      (await repo.log(mid)).map((l) => l.stage),
      containsAllInOrder(['queued', 'sent', 'delivered']),
    );

    // Python -> Dart
    peer.send({
      'cmd': 'send',
      'dest_hash': node.addressHex,
      'content': 'reply from python',
    });
    await waitFor(() async => (await repo.messages(chat)).length == 2);
    final incoming = (await repo.messages(chat)).last;
    expect(incoming.text, 'reply from python');
    expect(incoming.direction, 'in');
    expect(incoming.signatureValid, isTrue);
    await peer.waitFor('delivered');
  });
}
