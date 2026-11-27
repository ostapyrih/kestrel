import 'dart:async';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';

import '../bridge/bridge_service.dart';
import '../storage/chat_target.dart';
import '../storage/database.dart';
import '../storage/repo.dart';
import 'identity_store.dart';
import 'sqlite_lxm_store.dart';

enum NodeConnection { offline, connecting, online }

/// Default interval of the periodic mail check, minutes.
const defaultPropagationIntervalMinutes = 15;

/// Snapshot of the propagation ("mail via node") state for the UI.
class PropagationView {
  const PropagationView({
    required this.nodes,
    required this.active,
    required this.pinned,
    required this.progress,
    required this.lastSync,
    required this.fallback,
    required this.intervalMinutes,
  });

  final List<LxmPropagationNode> nodes;

  /// Node in use (pinned or auto-selected); null if none is known.
  final Uint8List? active;

  /// Hash pinned in Settings; null = automatic.
  final Uint8List? pinned;
  final LxmSyncProgress progress;
  final LxmSyncResult? lastSync;

  /// Fall back to the node when direct delivery fails.
  final bool fallback;

  /// Periodic sync interval in minutes; 0 = off.
  final int intervalMinutes;

  bool get syncing =>
      progress.phase != LxmSyncPhase.idle &&
      progress.phase != LxmSyncPhase.complete &&
      progress.phase != LxmSyncPhase.failed;

  LxmPropagationNode? get activeNode {
    final a = active;
    if (a == null) return null;
    final h = toHex(a);
    for (final n in nodes) {
      if (n.hashHex == h) return n;
    }
    return null;
  }
}

/// Creates the network interface for [host]:[port]. The default is a
/// `TcpClientInterface`; tests inject in-memory interfaces.
typedef InterfaceFactory = RnsInterface Function(String host, int port);

RnsInterface defaultInterfaceFactory(String host, int port) =>
    TcpClientInterface(
      host: host,
      port: port,
      reconnectDelay: const Duration(seconds: 3),
      maxReconnectDelay: const Duration(seconds: 30),
    );

/// Runs Reticulum + the LXMF router for identity B (Standalone mode), and
/// mirrors everything that happens into SQLite: incoming messages, outgoing
/// messages and every delivery state transition (`messages` + `delivery_log`).
///
/// Lives in the foreground; a background service is a later phase.
class NodeService {
  NodeService({
    required this.repo,
    required this.secrets,
    this.interfaceFactory = defaultInterfaceFactory,
    this.transportConfig = const TransportConfig(),
    this.routerConfig = const LxmRouterConfig(),
    KestrelStorage? rnsStorage,
  }) : _rnsStorage = rnsStorage ?? MemoryStorage();

  final Repo repo;
  final SecretStore secrets;
  final InterfaceFactory interfaceFactory;
  final TransportConfig transportConfig;
  final LxmRouterConfig routerConfig;
  final KestrelStorage _rnsStorage;

  BridgeService? _bridge;

  /// Account A: set by `main` (null in Standalone-only setups and tests).
  BridgeService? get bridge => _bridge;
  set bridge(BridgeService? b) {
    _bridge = b;
    // another device's `delete_chat` may remove queued messages of ours
    b?.vault.cancelOutbound = cancelOutboundHashes;
  }

  Reticulum? _rns;
  LxmRouter? _router;
  RnsInterface? _iface;
  Identity? _identity;
  StreamSubscription<InterfaceState>? _ifaceSub;
  final List<StreamSubscription<Object?>> _subs = [];
  final _ready = Completer<void>();
  final _connection = StreamController<NodeConnection>.broadcast();
  NodeConnection _current = NodeConnection.offline;
  Future<void> _eventTail = Future.value();
  bool _announcedThisConnection = false;
  bool _stopped = false;

  /// Completes when identity and router are running.
  Future<void> get ready => _ready.future;

  NodeConnection get connection => _current;
  Stream<NodeConnection> get connectionChanges => _connection.stream;

  Reticulum get rns => _rns!;
  Identity get identity => _identity!;
  LxmRouter get router => _router!;
  bool get isRunning => _router != null;

  /// Our LXMF address (destination hash), lower-case hex.
  String get addressHex => toHex(router.address);

  /// Identity B public key (64 bytes), hex: what the bridge whitelists.
  String get publicKeyHex => toHex(identity.publicKey);

  Future<void> start() async {
    try {
      _identity = await IdentityStore(secrets).loadOrCreate();
      final host =
          await repo.getSetting(SettingKeys.serverHost) ?? defaultServerHost;
      final port =
          int.tryParse(await repo.getSetting(SettingKeys.serverPort) ?? '') ??
          defaultServerPort;
      final name = await repo.getSetting(SettingKeys.displayName);
      _intervalMinutes = await _intervalSetting();

      final iface = interfaceFactory(host, port);
      _iface = iface;
      _rns = await Reticulum.start(
        ReticulumConfig(
          interfaces: [iface],
          storage: _rnsStorage,
          transport: transportConfig,
        ),
      );
      _router = await LxmRouter.start(
        _rns!,
        _identity!,
        displayName: (name == null || name.isEmpty) ? null : name,
        config: routerConfig,
        store: SqliteLxmStore(repo),
      );
      await repo.setAccountAddress(
        'B',
        addressHash: addressHex,
        displayName: name,
      );

      await _applyPropagationSettings();
      // Persisted by the router before it counts a message as handled: a
      // propagation node only deletes its copy after this has returned.
      _router!.inboundPersister = _persistIncoming;
      _subs
        ..add(
          _router!.outboundEvents.listen(
            (e) => _chain(() => _onOutboundEvent(e)),
          ),
        )
        ..add(_router!.peerUpdates.listen((p) => _chain(() => _onPeer(p))));
      for (final p in _router!.knownPeers) {
        _chain(() => _onPeer(p));
      }
      _watchInterface(iface);
      if (!_ready.isCompleted) _ready.complete();
    } on Object catch (e, st) {
      if (!_ready.isCompleted) _ready.completeError(e, st);
      rethrow;
    }
  }

  void _watchInterface(RnsInterface iface) {
    _ifaceSub?.cancel();
    _ifaceSub = iface.stateChanges.listen(_onInterfaceState);
    _onInterfaceState(iface.state);
  }

  void _onInterfaceState(InterfaceState s) {
    final c = switch (s) {
      InterfaceState.online => NodeConnection.online,
      InterfaceState.connecting => NodeConnection.connecting,
      InterfaceState.offline => NodeConnection.offline,
    };
    if (c == _current) return;
    _current = c;
    if (!_connection.isClosed) _connection.add(c);
    if (c == NodeConnection.online) {
      if (!_announcedThisConnection) {
        _announcedThisConnection = true;
        unawaited(announce());
      }
    } else {
      _announcedThisConnection = false;
    }
  }

  /// Announces our delivery destination (stamp generation runs off the UI
  /// isolate, so the first announce can take a while).
  Future<void> announce() async {
    await ready;
    try {
      await router.announce();
    } on Object {
      // announce is best effort
    }
  }

  void _chain(Future<void> Function() f) {
    _eventTail = _eventTail.then((_) => f()).catchError((Object _) {});
  }

  /// Waits for all queued event handlers (tests).
  Future<void> flushEvents() async {
    await Future<void>.delayed(Duration.zero);
    await _eventTail;
  }

  // ------------------------------------------------------------ propagation

  Future<void> _applyPropagationSettings() async {
    final r = _router!;
    final pinned = await repo.getSetting(SettingKeys.propagationNode);
    r.setPinnedNode(
      (pinned == null || !isValidAddress(pinned)) ? null : fromHex(pinned),
    );
    r.fallbackToPropagation =
        (await repo.getSetting(SettingKeys.propagationFallback)) != '0';
    final iv = await _intervalSetting();
    r.setSyncInterval(iv == 0 ? null : Duration(minutes: iv));
  }

  Future<int> _intervalSetting() async {
    final v = int.tryParse(
      await repo.getSetting(SettingKeys.propagationInterval) ?? '',
    );
    return v == null || v < 0 ? defaultPropagationIntervalMinutes : v;
  }

  int _intervalMinutes = defaultPropagationIntervalMinutes;
  Stream<PropagationView>? _propView;

  /// Current propagation state.
  PropagationView get propagation {
    final r = router;
    return PropagationView(
      nodes: r.propagationNodes,
      active: r.activeNode,
      pinned: r.pinnedNode,
      progress: r.syncProgress,
      lastSync: r.lastSync,
      fallback: r.fallbackToPropagation,
      intervalMinutes: _intervalMinutes,
    );
  }

  /// Emits whenever nodes, selection, sync progress or settings change.
  Stream<PropagationView> get propagationChanges =>
      _propView ??= router.propagationUpdates.map((_) => propagation);

  /// "Check mail" button: syncs now (also when the periodic sync is off).
  Future<LxmSyncResult> syncMail() async {
    await ready;
    final r = await router.syncInbox();
    await repo.setSetting(
      SettingKeys.propagationLastSync,
      '${r.at.millisecondsSinceEpoch}|${r.error.name}|${r.delivered}',
    );
    return r;
  }

  /// Pins [hashHex] as the propagation node; null = automatic.
  Future<void> setPropagationNode(String? hashHex) async {
    final h = hashHex?.trim().toLowerCase();
    final valid = h != null && isValidAddress(h);
    await repo.setSetting(SettingKeys.propagationNode, valid ? h : '');
    await ready;
    router.setPinnedNode(valid ? fromHex(h) : null);
  }

  Future<void> setPropagationFallback(bool on) async {
    await repo.setSetting(SettingKeys.propagationFallback, on ? '1' : '0');
    await ready;
    router.fallbackToPropagation = on;
    router.setPinnedNode(router.pinnedNode); // notifies listeners
  }

  /// Sets the periodic sync interval; 0 turns it off.
  Future<void> setPropagationInterval(int minutes) async {
    await repo.setSetting(SettingKeys.propagationInterval, '$minutes');
    await ready;
    _intervalMinutes = minutes;
    router.setSyncInterval(minutes == 0 ? null : Duration(minutes: minutes));
    router.setPinnedNode(router.pinnedNode); // notifies listeners
  }

  // ------------------------------------------------------------------ settings

  /// Changes the display name and re-announces.
  Future<void> setDisplayName(String name) async {
    final n = name.trim();
    await repo.setSetting(SettingKeys.displayName, n);
    await repo.setAccountAddress('B', displayName: n);
    await ready;
    router.setDisplayName(n);
    unawaited(announce());
  }

  /// Persists the server and reconnects the interface to it.
  Future<void> setServer(String host, int port) async {
    await repo.setSetting(SettingKeys.serverHost, host.trim());
    await repo.setSetting(SettingKeys.serverPort, '$port');
    await ready;
    final rns = _rns!;
    final old = _iface;
    if (old != null) {
      await rns.transport.removeInterface(old);
      await old.stop();
    }
    final i = interfaceFactory(host.trim(), port);
    _iface = i;
    await rns.addInterface(i);
    _watchInterface(i);
  }

  // ------------------------------------------------------------------ chats

  /// Resolves the conversation with [peerHashHex] under account B, or under
  /// account A when [identity] is `'A'` (bridge mode only). Never stores
  /// anything: when no chat exists yet the result is a draft (see
  /// [ChatTarget.isDraft]); the first [sendToPeer] creates the chat.
  Future<ChatTarget> openChat(
    String peerHashHex, {
    String? name,
    String identity = 'B',
  }) async {
    final h = peerHashHex.trim().toLowerCase();
    if (identity == 'A') {
      final b = bridge;
      if (b == null) throw StateError('bridge is not available');
      return b.openAChat(h, name: name);
    }
    return ChatTarget(
      chatId: await repo.findChatId('B', h),
      identity: 'B',
      peer: h,
      name: name,
    );
  }

  /// Sends the first (or any) message to [t]'s peer. For a draft the chat row,
  /// the message and its outbox entry are created in one transaction. Returns
  /// chat and message ids.
  Future<({int chatId, int messageId})> sendToPeer(
    ChatTarget t,
    String text, {
    bool viaNode = false,
  }) async {
    await ready;
    if (t.identity == 'A') {
      final b = bridge;
      if (b == null) throw StateError('bridge is not available');
      return b.sendToPeer(t.peer, text, name: t.name);
    }
    final ids = await _sendB(
      chatId: t.chatId,
      peer: t.peer,
      title: t.name,
      text: text,
      viaNode: viaNode,
    );
    return ids;
  }

  /// Cancels queued messages in the LXMF router (no-op while it is down).
  Future<void> cancelOutboundHashes(List<String> hashes) async {
    if (!isRunning) return;
    for (final h in hashes) {
      try {
        await router.cancel(fromHex(h));
      } on Object {
        // already gone
      }
    }
  }

  /// Unsent messages that deleting [chatIds] would cancel.
  Future<int> unsentCount(Iterable<int> chatIds) => repo.unsentCount(chatIds);

  /// Why [chatIds] cannot be deleted right now (`null` = they can):
  /// `delete_a_offline` / `delete_a_upstream` (MeshChatX down) /
  /// `delete_a_old_bridge` for account A chats,
  /// `delete_remote_no_vault` for chats of other devices.
  Future<String?> deleteBlockReason(Iterable<int> chatIds) async {
    var a = false;
    var remote = false;
    for (final id in chatIds) {
      if (isRemoteId(id)) {
        remote = true;
      } else if ((await repo.chat(id))?.accountIdentity == 'A') {
        a = true;
      }
    }
    final b = bridge;
    if (a) {
      if (b == null || !(b.api?.linkUp ?? false)) return 'delete_a_offline';
      if (!b.upstreamOk) return 'delete_a_upstream';
      if (!b.canDeleteChat) return 'delete_a_old_bridge';
    }
    if (remote && !(b?.vault.canDeleteRemote ?? false)) {
      return 'delete_remote_no_vault';
    }
    return null;
  }

  /// Deletes chats of every kind (the confirmation was shown by the UI):
  ///  * B chats of this device: hard delete here, unsent messages cancelled;
  ///    a `delete_chat` vault blob lets the other devices drop their copy;
  ///  * A chats: deleted in MeshChatX through the bridge for all devices;
  ///  * read-only chats of another device: deleted on every device, the
  ///    owner included (vault blob naming it as `owner_device`).
  /// Throws before changing anything when [deleteBlockReason] is non-null.
  Future<void> deleteChats(Iterable<int> chatIds) async {
    final ids = chatIds.toSet();
    if (await deleteBlockReason(ids) != null) {
      throw StateError('chats cannot be deleted now');
    }
    final a = <int>[];
    final own = <int>[];
    final remote = <int>[];
    for (final id in ids) {
      if (isRemoteId(id)) {
        remote.add(id);
        continue;
      }
      final c = await repo.chat(id);
      if (c == null || c.kind != 'lxmf') continue;
      (c.accountIdentity == 'A' ? a : own).add(id);
    }
    for (final id in own) {
      final c = await repo.chat(id);
      if (c?.peerHash != null && isRunning) {
        await cancelOutboundHashes(
          await repo.unsentHashes(c!.peerHash!, 1 << 52),
        );
      }
    }
    await repo.deleteChats(own);
    for (final id in remote) {
      final c = await repo.remoteChat(id);
      if (c?.remoteDeviceId == null || c?.peerHash == null) continue;
      await repo.removeVaultHistory(
        c!.remoteDeviceId!,
        c.peerHash!,
        uploadDelete: true,
      );
    }
    Object? failure;
    for (final id in a) {
      try {
        await bridge!.deleteAChat(id);
      } on Object catch (e) {
        failure ??= e;
      }
    }
    if (failure != null) throw failure;
  }

  static final _hexHash = RegExp(r'^[0-9a-fA-F]{32}$');

  /// True if [s] is a 16 byte hash in hex (an LXMF address).
  static bool isValidAddress(String s) => _hexHash.hasMatch(s.trim());

  // ------------------------------------------------------------------ sending

  /// Sends [text] in [chatId] from identity B. The message and its outbox
  /// entry (frozen sender and route) are written before anything touches the
  /// network, so nothing is lost if the app dies or the network is down.
  ///
  /// With [viaNode] the message goes straight to the propagation node
  /// ("send via node") instead of trying the recipient first.
  Future<int> sendMessage(
    int chatId,
    String text, {
    bool viaNode = false,
  }) async {
    await ready;
    final chat = await repo.chat(chatId);
    if (chat == null || chat.peerHash == null) {
      throw StateError('unknown chat');
    }
    if (chat.accountIdentity != 'B') {
      final b = bridge;
      if (b == null) throw StateError('bridge is not available');
      return b.sendMessage(chatId, text);
    }
    return (await _sendB(
      chatId: chatId,
      peer: chat.peerHash!,
      text: text,
      viaNode: viaNode,
    )).messageId;
  }

  Future<({int messageId, int chatId})> _sendB({
    int? chatId,
    required String peer,
    String? title,
    required String text,
    bool viaNode = false,
  }) async {
    final method = viaNode ? LxmfMethod.propagated : LxmfMethod.opportunistic;
    final ids = await repo.insertOutgoing(
      identity: 'B',
      chatId: chatId,
      newChatTitle: title,
      destinationHash: peer,
      text: text,
      route: _routeName(method),
      transport: _current == NodeConnection.online ? 'tcp' : 'none',
    );
    final o = await router.send(
      destinationHash: fromHex(peer),
      content: text,
      method: method,
      tag: '${ids.outboxId}',
    );
    await repo.updateMessage(
      ids.messageId,
      lxmfHash: toHex(o.hash),
      route: _routeName(o.method),
    );
    return (messageId: ids.messageId, chatId: ids.chatId);
  }

  static String _routeName(int method) => switch (method) {
    LxmfMethod.direct => 'direct',
    LxmfMethod.propagated => 'propagated',
    _ => 'opportunistic',
  };

  // ------------------------------------------------------------------ events

  /// Stores an inbound message. Throws on any real failure so the router
  /// does not acknowledge it to a propagation node; an already stored message
  /// (same LXMF hash) counts as persisted.
  Future<void> _persistIncoming(LxmReceived r) async {
    final m = r.message;
    // Service messages from the bridge (LXMF fallback) are not chat messages.
    if (bridge?.handleLxmf(m) ?? false) return;
    final hash = toHex(m.hash!);
    if (await repo.hasMessageHash('B', hash)) return;
    final peerHex = toHex(m.sourceHash);
    final peer = router.peer(m.sourceHash);
    final chatId = await repo.findOrCreateChat(
      'B',
      peerHex,
      title: peer?.displayName,
    );
    await repo.insertIncoming(
      identity: 'B',
      chatId: chatId,
      lxmfHash: hash,
      text: m.contentAsString,
      title: m.title.isEmpty ? null : m.titleAsString,
      ts: DateTime.fromMillisecondsSinceEpoch(
        ((m.timestamp ?? DateTime.now().millisecondsSinceEpoch / 1000) * 1000)
            .round(),
      ),
      route: _routeName(r.method),
      transport: 'tcp',
      signatureValid: m.signatureValidated,
    );
  }

  Future<void> _onPeer(LxmPeer p) => repo.upsertPeer(
    toHex(p.hash),
    displayName: p.displayName,
    stampCost: p.stampCost,
    hops: p.hops,
  );

  Future<void> _onOutboundEvent(LxmOutboundEvent e) async {
    final oid = int.tryParse(e.tag ?? '');
    if (oid == null) return;
    final ob = await repo.outbox(oid);
    if (ob == null) return;
    final status = switch (e.state) {
      LxmState.generating || LxmState.outbound => MsgStatus.queued,
      LxmState.sending => MsgStatus.sending,
      LxmState.sent => MsgStatus.sent,
      LxmState.delivered => MsgStatus.delivered,
      _ => MsgStatus.failed,
    };
    final onWire =
        e.state == LxmState.sent ||
        e.state == LxmState.sending ||
        e.state == LxmState.delivered;
    await repo.updateMessage(
      ob.messageId,
      lxmfHash: toHex(e.hash),
      status: status,
      route: _routeName(e.method),
      transport: onWire ? 'tcp' : null,
      error: e.error,
    );
    // The creation of the outbox row already logged "queued".
    if (e.stage != 'queued') {
      await repo.addLog(ob.messageId, e.stage, detail: e.error, at: e.at);
    }
  }

  // ---------------------------------------------------------------- lifecycle

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _ifaceSub?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    await _router?.stop();
    await _rns?.stop();
    await _connection.close();
  }
}
