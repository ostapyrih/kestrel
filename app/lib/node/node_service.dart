import 'dart:async';

import 'package:kestrel_rns/kestrel_rns.dart';

import '../bridge/bridge_service.dart';
import '../storage/database.dart';
import '../storage/repo.dart';
import 'identity_store.dart';
import 'sqlite_lxm_store.dart';

enum NodeConnection { offline, connecting, online }

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

  /// Account A: set by `main` (null in Standalone-only setups and tests).
  BridgeService? bridge;

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

      _subs
        ..add(_router!.incoming.listen((m) => _chain(() => _onIncoming(m))))
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

  /// Opens (or creates) the chat with [peerHashHex] under account B.
  Future<int> openChat(String peerHashHex, {String? name}) async {
    final h = peerHashHex.trim().toLowerCase();
    return repo.findOrCreateChat('B', h, title: name);
  }

  static final _hexHash = RegExp(r'^[0-9a-fA-F]{32}$');

  /// True if [s] is a 16 byte hash in hex (an LXMF address).
  static bool isValidAddress(String s) => _hexHash.hasMatch(s.trim());

  // ------------------------------------------------------------------ sending

  /// Sends [text] in [chatId] from identity B. The message and its outbox
  /// entry (frozen sender and route) are written before anything touches the
  /// network, so nothing is lost if the app dies or the network is down.
  Future<int> sendMessage(int chatId, String text) async {
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
    final ids = await repo.insertOutgoing(
      identity: 'B',
      chatId: chatId,
      destinationHash: chat.peerHash!,
      text: text,
      route: 'opportunistic',
      transport: _current == NodeConnection.online ? 'tcp' : 'none',
    );
    final o = await router.send(
      destinationHash: fromHex(chat.peerHash!),
      content: text,
      method: LxmfMethod.opportunistic,
      tag: '${ids.outboxId}',
    );
    await repo.updateMessage(
      ids.messageId,
      lxmfHash: toHex(o.hash),
      route: _routeName(o.method),
    );
    return ids.messageId;
  }

  static String _routeName(int method) => switch (method) {
    LxmfMethod.direct => 'direct',
    LxmfMethod.propagated => 'propagated',
    _ => 'opportunistic',
  };

  // ------------------------------------------------------------------ events

  Future<void> _onIncoming(LxmReceived r) async {
    final m = r.message;
    // Service messages from the bridge (LXMF fallback) are not chat messages.
    if (bridge?.handleLxmf(m) ?? false) return;
    final peerHex = toHex(m.sourceHash);
    final peer = router.peer(m.sourceHash);
    final chatId = await repo.findOrCreateChat(
      'B',
      peerHex,
      title: peer?.displayName,
    );
    try {
      await repo.insertIncoming(
        identity: 'B',
        chatId: chatId,
        lxmfHash: toHex(m.hash!),
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
    } on Object {
      // duplicate (unique index): already stored
    }
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
