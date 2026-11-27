import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart';
import 'package:kestrel/bridge/bridge_connection.dart';
import 'package:kestrel/bridge/bridge_service.dart';
import 'package:kestrel/bridge/bridge_store.dart';
import 'package:kestrel/bridge/codec.dart';
import 'package:kestrel/bridge/vault_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/node/node_service.dart';
import 'package:kestrel/providers.dart';
import 'package:kestrel/storage/chat_target.dart';
import 'package:kestrel/storage/repo.dart';

final fakeAddress = '0123456789abcdef' * 2;
final fakePublicKey = 'fedcba9876543210' * 8;

/// Records calls instead of touching the network.
class FakeNode extends Fake implements NodeService {
  final List<(int, String)> sent = [];
  final List<String> opened = [];
  final List<String> openedAs = [];
  final List<String> names = [];
  final List<(String, int)> servers = [];

  /// Scripted answers for the chat deletion flow.
  String? deleteReason;
  int unsent = 0;
  final List<List<int>> deleted = [];

  @override
  Future<String?> deleteBlockReason(Iterable<int> chatIds) async =>
      deleteReason;

  @override
  Future<int> unsentCount(Iterable<int> chatIds) async => unsent;

  @override
  Future<void> deleteChats(Iterable<int> chatIds) async =>
      deleted.add(chatIds.toList());

  @override
  Future<int> sendMessage(int chatId, String text) async {
    sent.add((chatId, text));
    return 1;
  }

  @override
  Future<ChatTarget> openChat(
    String peerHashHex, {
    String? name,
    String identity = 'B',
  }) async {
    opened.add(peerHashHex);
    openedAs.add(identity);
    return ChatTarget(
      chatId: draft ? null : 1,
      identity: identity,
      peer: peerHashHex,
      name: name,
    );
  }

  /// Opened conversations are drafts (no chat row yet) when true.
  bool draft = false;
  final draftSends = <(String, String)>[];

  @override
  Future<({int chatId, int messageId})> sendToPeer(
    ChatTarget t,
    String text,
  ) async {
    draftSends.add((t.peer, text));
    return (chatId: 1, messageId: 1);
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

/// A history synced from the user's iPhone (vault): read only.
final fixtureRemoteChat = ChatRow(
  id: -1,
  accountIdentity: 'B',
  kind: 'lxmf',
  peerHash: 'cc' * 16,
  title: 'Remote peer',
  lastTs: _t0 - 120000,
  unread: 0,
  lastText: 'Написано на айфоні',
  remoteDeviceId: 'd1' * 16,
  remoteDeviceName: 'iPhone',
);

final fixtureRemoteMessages = [
  MessageRow(
    id: -1,
    chatId: -1,
    direction: 'out',
    lxmfHash: 'ee' * 16,
    text: 'Написано на айфоні',
    ts: _t0 - 120000,
    senderIdentity: 'B',
    route: 'direct',
    transport: 'tcp',
    status: 'delivered',
    error: null,
    signatureValid: null,
    originDevice: 'd1' * 16,
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

/// Records bridge actions instead of touching the network.
class FakeBridge extends Fake implements BridgeService {
  final List<String> openedA = [];

  @override
  Future<ChatTarget> openAChat(String peerHash, {String? name}) async {
    openedA.add(peerHash);
    return ChatTarget(identity: 'A', peer: peerHash, name: name);
  }

  final List<int> cancelled = [];
  final List<int> sentFromB = [];
  final List<String> renamed = [];
  final List<(String, bool)> roles = [];
  final List<String> revoked = [];
  final List<String> approved = [];
  final List<String> configured = [];
  final List<String> rrcSent = [];
  final List<bool> enabled = [];
  Object? approveError;
  Object? inviteError;
  Duration inviteTtl = const Duration(minutes: 10);
  int invitesCreated = 0;
  final List<String> deviceNames = [];
  final List<String> redeemedInvites = [];
  Object? redeemError;

  @override
  Future<InviteQr> createInvite() async {
    if (inviteError != null) throw inviteError!;
    invitesCreated++;
    return InviteQr(
      'kestrel-invite:v1:test$invitesCreated',
      DateTime.now().add(inviteTtl),
    );
  }

  @override
  Future<DeviceRecord> redeemInvite(String text) async {
    if (redeemError != null) throw redeemError!;
    redeemedInvites.add(text);
    return DeviceRecord(
      deviceId: 'ee' * 16,
      publicKey: '',
      name: 'x',
      platform: 'linux',
      roles: const [],
      bootstrap: false,
      addedBy: 'dd' * 16,
      addedAt: 1,
    );
  }

  @override
  Future<void> setDeviceName(String name) async => deviceNames.add(name);

  @override
  Future<bool> cancelQueued(int messageId) async {
    cancelled.add(messageId);
    return true;
  }

  @override
  Future<int?> sendFromBInstead(int messageId) async {
    sentFromB.add(messageId);
    return 99;
  }

  @override
  Future<void> markRead(int chatId) async {}

  @override
  Future<bool> loadOlder(int chatId) async => false;

  @override
  Future<List<DeviceRecord>> refreshDevices() async => const [];

  @override
  Future<void> refreshRooms() async {}

  @override
  Future<void> loadRoom(String hub, String room) async {}

  @override
  Future<bool> loadOlderRoom(String hub, String room) async => false;

  @override
  Future<void> sendRrc(String hub, String room, String text) async {
    if (BridgeService.isRrcCommand(text)) throw RrcCommandBlocked();
    rrcSent.add(text);
  }

  @override
  Future<void> renameDevice(String deviceId, String name) async =>
      renamed.add('$deviceId=$name');

  @override
  Future<void> setFieldRole(String deviceId, bool enabled) async =>
      roles.add((deviceId, enabled));

  @override
  Future<void> revokeDevice(String deviceId, {String? reason}) async =>
      revoked.add(deviceId);

  @override
  Future<DeviceRecord> approveDevice(
    DecodedPairing d, {
    String? name,
    bool field = false,
  }) async {
    if (approveError != null) throw approveError!;
    approved.add('${d.payload.name}:$field');
    return DeviceRecord(
      deviceId: d.payload.deviceId,
      publicKey: '',
      name: d.payload.name,
      platform: d.payload.platform,
      roles: [if (field) 'field'],
      bootstrap: false,
    );
  }

  @override
  Future<PairingPayload> newPairingPayload() async => PairingPayload(
    pubkey: Uint8List.fromList(List.filled(64, 7)),
    name: 'New phone',
    platform: 'android',
    nonce: Uint8List.fromList(List.filled(16, 9)),
    ts: 1700000000,
  );

  @override
  Future<void> beginPairing() async {}

  @override
  void endPairing() {}

  @override
  Future<void> configure(String text) async {
    if (extractBridgePublicKey(text) == null) throw const FormatException('x');
    configured.add(text);
  }

  @override
  Future<void> setEnabled(bool on) async => enabled.add(on);

  int queuedUnsent = 0;
  final List<String> turnedOff = [];

  @override
  Future<int> queuedSendCount() async => queuedUnsent;

  @override
  Future<void> turnOff({bool sendQueuedFromB = false}) async =>
      turnedOff.add(sendQueuedFromB ? 'send-from-b' : 'discard');

  @override
  bool get syncing => false;

  @override
  Stream<bool> get syncingChanges => const Stream.empty();

  @override
  Future<void> setFallback(bool on) async {}
}

MessageRow _ma(
  int id,
  String dir,
  String text,
  String status, {
  String? origin,
  String route = 'direct',
  String? hash,
}) => MessageRow(
  id: id,
  chatId: 2,
  direction: dir,
  lxmfHash: hash,
  text: text,
  ts: _t0 + id * 1000,
  senderIdentity: 'A',
  route: route,
  transport: 'tcp',
  status: status,
  error: null,
  signatureValid: null,
  originDevice: origin,
);

final fixtureADevices = [
  DeviceRecord(
    deviceId: 'd1' * 16,
    publicKey: '',
    name: 'iPhone',
    platform: 'ios',
    roles: const [],
    bootstrap: true,
    lastSeen: 1700000000,
    online: true,
  ),
  DeviceRecord(
    deviceId: 'd2' * 16,
    publicKey: '',
    name: 'Old laptop',
    platform: 'windows',
    roles: const ['field'],
    bootstrap: false,
    revokedAt: 1700000500,
  ),
];

/// Messages of the A chat (id 2): from the iPhone, typed in MeshChatX, and
/// one that waits for the bridge.
final fixtureAMessages = [
  _ma(11, 'in', 'Через міст', 'received'),
  _ma(12, 'out', 'З айфона', 'delivered', origin: 'd1' * 16, hash: 'cd' * 16),
  _ma(13, 'out', 'З вебу', 'delivered', hash: 'ef' * 16),
  _ma(14, 'out', 'Чекає', 'queued', route: 'via_bridge'),
];

List<Override> fixtureOverrides({
  required NodeConnection conn,
  FakeNode? node,
  Repo? repo,
  FakeBridge? bridge,
  BridgeStatus bridgeStatus = const BridgeStatus(BridgeState.off),
  bool bridgeConfigured = false,

  /// Bridge mode on/off; defaults to [bridgeConfigured]. [bridgeEnabledStream]
  /// lets a test flip it while the widgets are on screen.
  bool? bridgeEnabled,
  Stream<bool>? bridgeEnabledStream,
  List<DeviceRecord>? devices,

  /// Adds the read-only history of another device to the chat list.
  bool withRemote = false,
  VaultStatus vaultStatus = const VaultStatus(state: VaultState.idle),
}) => [
  hasRemoteChatsProvider.overrideWith((ref) => Stream.value(withRemote)),
  vaultStatusProvider.overrideWith((ref) => Stream.value(vaultStatus)),
  bridgeProvider.overrideWithValue(bridge ?? FakeBridge()),
  bridgeStatusProvider.overrideWith((ref) => Stream.value(bridgeStatus)),
  bridgeConfiguredProvider.overrideWith(
    (ref) => Stream.value(bridgeConfigured),
  ),
  bridgeRevokedProvider.overrideWith((ref) => Stream.value(false)),
  bridgeDevicesProvider.overrideWith(
    (ref) => Stream.value(devices ?? fixtureADevices),
  ),
  rrcRoomsProvider.overrideWith(
    (ref) => Stream.value([
      RrcRoomRow('ee' * 16, 'Hub', 'general', 2, true),
      RrcRoomRow('ee' * 16, 'Hub', 'ops', 0, false),
    ]),
  ),
  rrcMessagesProvider.overrideWith(
    (ref, k) => Stream.value([
      RrcMessageRow(1, 'msg', 'ann', 'hello room', _t0, false),
    ]),
  ),
  nodeProvider.overrideWithValue(node ?? FakeNode()),
  if (repo != null) repoProvider.overrideWithValue(repo),
  connectionProvider.overrideWith((ref) => Stream.value(conn)),
  chatsProvider.overrideWith((ref) {
    final f = ref.watch(accountFilterProvider);
    final mode = ref.watch(bridgeModeProvider);
    final eff = mode ? f : 'B';
    return Stream.value([
      if (withRemote && mode && (eff == null || eff == 'R')) fixtureRemoteChat,
      for (final c in fixtureChats)
        if (eff != 'R' && (eff == null || c.accountIdentity == eff)) c,
    ]);
  }),
  chatProvider.overrideWith(
    (ref, id) => Stream.value(
      [...fixtureChats, fixtureRemoteChat].firstWhere((c) => c.id == id),
    ),
  ),
  messagesProvider.overrideWith(
    (ref, id) => Stream.value(
      id == 1
          ? fixtureMessages
          : id == -1
          ? fixtureRemoteMessages
          : id == 2
          ? fixtureAMessages
          : const <MessageRow>[],
    ),
  ),
  deliveryLogProvider.overrideWith((ref, id) => Stream.value(fixtureLog)),
  peersProvider.overrideWith(
    (ref) => Stream.value([PeerRow('aa' * 16, 'Alice', _t0, 1)]),
  ),
  settingProvider.overrideWith((ref, key) => Stream.value(null)),
  bridgeEnabledProvider.overrideWith(
    (ref) =>
        bridgeEnabledStream ?? Stream.value(bridgeEnabled ?? bridgeConfigured),
  ),
  identityInfoProvider.overrideWith(
    (ref) async => (address: fakeAddress, publicKey: fakePublicKey),
  ),
];
