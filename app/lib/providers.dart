import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'node/node_service.dart';
import 'storage/database.dart';
import 'storage/repo.dart';

/// Overridden in `main()` / tests with the real instances.
final repoProvider = Provider<Repo>((ref) => throw UnimplementedError());
final nodeProvider = Provider<NodeService>((ref) => throw UnimplementedError());

final connectionProvider = StreamProvider<NodeConnection>((ref) async* {
  final n = ref.watch(nodeProvider);
  yield n.connection;
  yield* n.connectionChanges;
});

/// Selected account chip: null = all, otherwise `A` or `B`.
class AccountFilter extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? v) => state = v;
}

final accountFilterProvider = NotifierProvider<AccountFilter, String?>(
  AccountFilter.new,
);

final chatsProvider = StreamProvider<List<ChatRow>>((ref) {
  final repo = ref.watch(repoProvider);
  final f = ref.watch(accountFilterProvider);
  return repo.watch(() => repo.chats(accountIdentity: f));
});

final chatProvider = StreamProvider.family<ChatRow?, int>((ref, id) {
  final repo = ref.watch(repoProvider);
  return repo.watch(() => repo.chat(id));
});

final messagesProvider = StreamProvider.family<List<MessageRow>, int>((
  ref,
  id,
) {
  final repo = ref.watch(repoProvider);
  return repo.watch(() => repo.messages(id));
});

final deliveryLogProvider = StreamProvider.family<List<LogRow>, int>((ref, id) {
  final repo = ref.watch(repoProvider);
  return repo.watch(() => repo.log(id));
});

final peersProvider = StreamProvider<List<PeerRow>>((ref) {
  final repo = ref.watch(repoProvider);
  return repo.watch(repo.peers);
});

final settingProvider = StreamProvider.family<String?, String>((ref, key) {
  final repo = ref.watch(repoProvider);
  return repo.watch(() => repo.getSetting(key));
});

final bridgeEnabledProvider = StreamProvider<bool>((ref) {
  final repo = ref.watch(repoProvider);
  return repo.watch(repo.bridgeEnabled);
});

/// Identity B facts shown in settings (available once the node is up).
typedef IdentityInfo = ({String address, String publicKey});

final identityInfoProvider = FutureProvider<IdentityInfo>((ref) async {
  final n = ref.watch(nodeProvider);
  await n.ready;
  return (address: n.addressHex, publicKey: n.publicKeyHex);
});

String serverLabel(String? host, String? port) =>
    '${host ?? defaultServerHost}:${port ?? defaultServerPort}';
