import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/node/node_service.dart';
import 'package:kestrel/providers.dart';
import 'package:kestrel/storage/repo.dart';

final fakeAddress = '0123456789abcdef' * 2;
final fakePublicKey = 'fedcba9876543210' * 8;

/// Records calls instead of touching the network.
class FakeNode extends Fake implements NodeService {
  final List<(int, String)> sent = [];
  final List<String> opened = [];
  final List<String> names = [];
  final List<(String, int)> servers = [];

  @override
  Future<int> sendMessage(int chatId, String text) async {
    sent.add((chatId, text));
    return 1;
  }

  @override
  Future<int> openChat(String peerHashHex, {String? name}) async {
    opened.add(peerHashHex);
    return 1;
  }

  @override
  Future<void> setDisplayName(String name) async => names.add(name);

  @override
  Future<void> setServer(String host, int port) async =>
      servers.add((host, port));
}

final _t0 = DateTime(2026, 11, 25, 12).millisecondsSinceEpoch;

final fixtureChats = [
  ChatRow(
    id: 1,
    accountIdentity: 'B',
    kind: 'lxmf',
    peerHash: 'aa' * 16,
    title: 'Alice',
    lastTs: _t0,
    unread: 0,
    lastText: 'Привіт!',
  ),
  ChatRow(
    id: 2,
    accountIdentity: 'A',
    kind: 'lxmf',
    peerHash: 'bb' * 16,
    title: 'Marichka',
    lastTs: _t0 - 60000,
    unread: 2,
    lastText: 'Через міст',
  ),
];

MessageRow _m(
  int id,
  String dir,
  String text,
  String status, {
  String route = 'opportunistic',
  String transport = 'tcp',
  String? hash,
  String? error,
}) => MessageRow(
  id: id,
  chatId: 1,
  direction: dir,
  lxmfHash: hash,
  text: text,
  ts: _t0 + id * 1000,
  senderIdentity: 'B',
  route: route,
  transport: transport,
  status: status,
  error: error,
  signatureValid: true,
);

final fixtureMessages = [
  _m(1, 'in', 'Привіт!', 'received'),
  _m(
    2,
    'out',
    'Вітаю, як справи?',
    'delivered',
    route: 'direct',
    hash: 'ab12cd34' * 8,
  ),
  _m(
    3,
    'out',
    'Невдала спроба',
    'failed',
    transport: 'none',
    error: 'max delivery attempts reached',
  ),
  _m(4, 'out', 'У черзі', 'queued', transport: 'none'),
];

final fixtureLog = [
  LogRow('queued', _t0 + 2000, 'opportunistic'),
  LogRow('link_established', _t0 + 3000, null),
  LogRow('sent', _t0 + 4000, null),
  LogRow('delivered', _t0 + 5000, null),
];

List<Override> fixtureOverrides({
  required NodeConnection conn,
  FakeNode? node,
  Repo? repo,
}) => [
  nodeProvider.overrideWithValue(node ?? FakeNode()),
  if (repo != null) repoProvider.overrideWithValue(repo),
  connectionProvider.overrideWith((ref) => Stream.value(conn)),
  chatsProvider.overrideWith((ref) {
    final f = ref.watch(accountFilterProvider);
    return Stream.value([
      for (final c in fixtureChats)
        if (f == null || c.accountIdentity == f) c,
    ]);
  }),
  chatProvider.overrideWith(
    (ref, id) => Stream.value(fixtureChats.firstWhere((c) => c.id == id)),
  ),
  messagesProvider.overrideWith(
    (ref, id) => Stream.value(id == 1 ? fixtureMessages : const []),
  ),
  deliveryLogProvider.overrideWith((ref, id) => Stream.value(fixtureLog)),
  peersProvider.overrideWith(
    (ref) => Stream.value([PeerRow('aa' * 16, 'Alice', _t0, 1)]),
  ),
  settingProvider.overrideWith((ref, key) => Stream.value(null)),
  bridgeEnabledProvider.overrideWith((ref) => Stream.value(false)),
  identityInfoProvider.overrideWith(
    (ref) async => (address: fakeAddress, publicKey: fakePublicKey),
  ),
];
