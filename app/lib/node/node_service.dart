import 'dart:async';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';

import '../bridge/bridge_connection.dart';
import '../bridge/bridge_service.dart';
import '../storage/chat_target.dart';
import '../storage/database.dart';
import '../storage/repo.dart';
import '../group/group_runtime.dart';
import '../group/group_service.dart';
import '../nomadnet/browser_sync.dart';
import '../platform.dart';
import 'identity_store.dart';
import 'sqlite_lxm_store.dart';

enum NodeConnection { offline, connecting, online }

/// Default interval of the periodic mail check, minutes.
const defaultPropagationIntervalMinutes = 15;

/// Destination hash of the owner's public propagation node (a public, announced
/// address). It is the selection on a fresh install and whenever the user has
/// not chosen a node; see [PropagationChoice].
const kDefaultPropagationNode = '9e0328edbea2a4e8bae44bccb5427d5a';

/// How the propagation node is chosen. Stored in
/// `SettingKeys.propagationNode`: absent or empty = [defaultNode] (also what
/// installs that never pinned a node migrate to), `auto` = [automatic], a
/// 32-char hash = [pinned].
enum PropagationChoice { defaultNode, automatic, pinned }

const propagationAutoSetting = 'auto';

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
    this.defaultNode,
    this.usingDefault = false,
    this.defaultUnreachable = false,
  });

  /// The default node (null if the selection never uses one).
  final Uint8List? defaultNode;

  /// True while the user has not chosen a node, so the default is preferred.
  final bool usingDefault;

  /// The default node failed recently and is being skipped for now.
  final bool defaultUnreachable;

  /// [defaultNode], or the built-in default when the view has none.
  Uint8List get defaultNodeOrConst =>
      defaultNode ?? fromHex(kDefaultPropagationNode);

  PropagationChoice get choice => pinned != null
      ? PropagationChoice.pinned
      : (usingDefault
            ? PropagationChoice.defaultNode
            : PropagationChoice.automatic);

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

/// Runs Reticulum + the LXMF router for the group identity G ("my address"), and
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
    this.announceOnConnect = true,
    this.groupSync = true,
    KestrelStorage? rnsStorage,
  }) : _rnsStorage = rnsStorage ?? MemoryStorage() {
    group = GroupService(repo: repo, secrets: secrets);
  }

  final Repo repo;
  final SecretStore secrets;
  final InterfaceFactory interfaceFactory;
  final TransportConfig transportConfig;
  final LxmRouterConfig routerConfig;

  /// Announce when the connection comes up. A short background check runs
  /// with this off: the foreground instance announces.
  final bool announceOnConnect;

  /// Runs the device sync and announcer election (off in the short
  /// background check: the foreground instance owns the group role, so the
  /// background one stays silent and does not touch G's propagation inbox).
  final bool groupSync;
  final KestrelStorage _rnsStorage;

  /// The device group: keys of G and of this device, device list, key chain.
  late final GroupService group;

  BridgeService? _bridge;

  /// Account A: set by `main` (null in Standalone-only setups and tests).
  BridgeService? get bridge => _bridge;
  set bridge(BridgeService? b) {
    _bridge = b;
    // another device's `delete_chat` may remove queued messages of ours
    b?.vault.cancelOutbound = cancelOutboundHashes;
    _bridgeStatusSub?.cancel();
    _bridgeStatusSub = b?.statusChanges.listen((st) {
      if (st.state == BridgeState.connected) {
        unawaited(migrateBridgeKeyIfNeeded());
      }
    });
  }

  StreamSubscription<BridgeStatus>? _bridgeStatusSub;
  bool _migratingBridgeKey = false;

  /// Moves this device's bridge registration from the legacy identity B to
  /// the hidden device key once the bridge is connected (see
  /// [BridgeService.migrateToDeviceKey]). Retried at the next connection if
  /// it fails.
  Future<void> migrateBridgeKeyIfNeeded() async {
    final b = _bridge;
    if (b == null || group.legacyIdentity == null || _migratingBridgeKey) {
      return;
    }
    _migratingBridgeKey = true;
    try {
      await b.migrateToDeviceKey(
        newKey: group.deviceIdentity,
        switchKey: () async {
          await group.bridgeMigrated();
          await b.reconnect();
        },
      );
    } on Object {
      // retried on the next connection
    } finally {
      _migratingBridgeKey = false;
    }
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

  /// The group identity G: the only identity used for chats.
  Identity get identity => _identity!;

  /// The hidden device key (never shown, never used for chats).
  Identity get deviceIdentity => group.deviceIdentity;

  /// The key this device authenticates to the bridge with: the old identity B
  /// until the bridge registration moved to the device key, then the device
  /// key.
  Identity get bridgeIdentity => group.legacyIdentity ?? group.deviceIdentity;
  LxmRouter get router => _router!;
  bool get isRunning => _router != null;

  /// Our LXMF address (destination hash), lower-case hex.
  String get addressHex => toHex(router.address);

  /// Public key of G (64 bytes), hex.
  String get publicKeyHex => toHex(identity.publicKey);

  Future<void> start() async {
    try {
      await group.init();
      _identity = group.groupIdentity;
      final host =
          await repo.getSetting(SettingKeys.serverHost) ?? defaultServerHost;
      final port =
          int.tryParse(await repo.getSetting(SettingKeys.serverPort) ?? '') ??
          defaultServerPort;
      final name = group.displayName.isNotEmpty
          ? group.displayName
          : await repo.getSetting(SettingKeys.displayName);
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
      await _startRouter(_identity!, name);
      await startGroupRuntimeIfNeeded();
      _watchInterface(iface);
      if (!_ready.isCompleted) _ready.complete();
    } on Object catch (e, st) {
      if (!_ready.isCompleted) _ready.completeError(e, st);
      rethrow;
    }
  }

  final List<StreamSubscription<Object?>> _routerSubs = [];

  GroupRuntime? _runtime;

  /// The running device sync (null for a single-device install).
  GroupRuntime? get groupRuntime => _runtime;

  /// Starts the device sync when the group has more than one device.
  Future<void> startGroupRuntimeIfNeeded() async {
    if (!groupSync ||
        _runtime != null ||
        !group.isGroup ||
        _router == null ||
        _rns == null) {
      return;
    }
    final rt = GroupRuntime(
      rns: _rns!,
      repo: repo,
      group: group,
      groupRouter: _router!,
      storage: _rnsStorage,
      routerConfig: routerConfig,
      internet: () => _current == NodeConnection.online,
      onRole: setAnnouncer,
      onName: (n) {
        _router?.setDisplayName(n);
        unawaited(repo.setAccountAddress('B', displayName: n));
      },
      onIdentity: (c) async {
        // switching restarts the runtime that delivered the record: do it
        // after this record has been fully handled
        unawaited(Future<void>(() => _adoptIdentity(c)));
      },
      browser: BrowserSyncStore(repo.adb),
    );
    _runtime = rt;
    // silent until the election says otherwise
    setAnnouncer(false);
    await rt.start();
  }

  Future<void> _stopRuntime() async {
    final rt = _runtime;
    _runtime = null;
    await rt?.stop();
  }

  /// Tells the siblings that [chatId] was read here.
  Future<void> publishRead(int chatId) async {
    final rt = _runtime;
    if (rt == null) return;
    final c = await repo.chat(chatId);
    if (c?.peerHash != null && c!.accountIdentity == 'B') {
      await rt.publishRead(c.peerHash!);
    }
  }

  /// Creates the LXMF router for [id] and wires it to the database.
  Future<void> _startRouter(Identity id, String? name) async {
    _router = await LxmRouter.start(
      _rns!,
      id,
      displayName: (name == null || name.isEmpty) ? null : name,
      config: routerConfig,
      store: SqliteLxmStore(repo),
    );
    // group-wide monotonic announce time (shared via the group state)
    _router!.destination.announceTimebase = AnnounceTimebase(
      lastEmitted: group.state.timebase,
      onChanged: (t) {
        if (group.state.mergeTimebase(t)) unawaited(group.persist());
      },
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
    _routerSubs
      ..add(
        _router!.outboundEvents.listen(
          (e) => _chain(() => _onOutboundEvent(e)),
        ),
      )
      ..add(_router!.peerUpdates.listen((p) => _chain(() => _onPeer(p))));
    for (final p in _router!.knownPeers) {
      _chain(() => _onPeer(p));
    }
    applyAnnouncerRole();
  }

  /// A single device always announces; in a group the election
  /// ([GroupAnnouncer]) decides once [startGroupRuntimeIfNeeded] ran.
  void applyAnnouncerRole() {
    if (_runtime == null) setAnnouncer(groupSync || !group.isGroup);
  }

  /// Makes this device the announcer of G (or silent). The announcer alone
  /// announces, answers path requests and syncs the propagation inbox.
  void setAnnouncer(bool on) {
    final r = _router;
    if (r == null) return;
    r.silent = !on;
    r.destination.ratchetRotationAllowed = on;
    r.inboxSyncEnabled = on;
  }

  Future<void> _stopRouter() async {
    for (final s in _routerSubs) {
      await s.cancel();
    }
    _routerSubs.clear();
    final r = _router;
    if (r != null) {
      _rns?.transport.deregisterDestination(r.destination);
      await r.stop();
    }
    _router = null;
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
      if (announceOnConnect && !_announcedThisConnection) {
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
      final rt = _runtime;
      if (rt != null) {
        if (rt.isAnnouncer) await rt.sync.announceGroup(router);
        unawaited(rt.announceDevice());
      } else {
        await router.announce();
      }
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
    final stored = await repo.getSetting(SettingKeys.propagationNode);
    switch (propagationChoiceOf(stored)) {
      case PropagationChoice.pinned:
        r.setDefaultNode(null);
        r.setPinnedNode(fromHex(stored!.trim().toLowerCase()));
      case PropagationChoice.automatic:
        r.setDefaultNode(null);
        r.setPinnedNode(null);
      case PropagationChoice.defaultNode:
        r.setDefaultNode(fromHex(kDefaultPropagationNode));
        r.setPinnedNode(null);
    }
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

  /// Maps the stored setting to a choice. Anything that is not `auto` or a
  /// valid hash (absent, the old "automatic" empty string) is the default.
  static PropagationChoice propagationChoiceOf(String? stored) {
    final v = stored?.trim().toLowerCase();
    if (v == propagationAutoSetting) return PropagationChoice.automatic;
    if (v != null && isValidAddress(v)) return PropagationChoice.pinned;
    return PropagationChoice.defaultNode;
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
      defaultNode: r.defaultNode,
      usingDefault: r.defaultNode != null && r.pinnedNode == null,
      defaultUnreachable:
          r.defaultNode != null && r.isNodeUnreachable(r.defaultNode!),
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

  /// Pins [hashHex] as the propagation node; null = automatic selection
  /// (an explicit choice that overrides the default node).
  Future<void> setPropagationNode(String? hashHex) async {
    final h = hashHex?.trim().toLowerCase();
    final valid = h != null && isValidAddress(h);
    await repo.setSetting(
      SettingKeys.propagationNode,
      valid ? h : propagationAutoSetting,
    );
    await ready;
    router.setDefaultNode(null);
    router.setPinnedNode(valid ? fromHex(h) : null);
  }

  /// Back to the default node ([kDefaultPropagationNode]).
  Future<void> resetPropagationNode() async {
    await repo.setSetting(SettingKeys.propagationNode, '');
    await ready;
    router.setPinnedNode(null);
    router.setDefaultNode(fromHex(kDefaultPropagationNode));
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
    await group.setDisplayName(n);
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

  // ------------------------------------------------------- extra interfaces

  final List<RnsInterface> _extra = [];
  final Map<RnsInterface, StreamSubscription<InterfaceState>> _extraSubs = {};

  /// Attaches another interface (the LoRa RNode) next to the TCP one:
  /// Transport uses all of them. Announces our address once whenever it
  /// comes online, so peers in radio range learn us.
  Future<void> addInterface(RnsInterface i) async {
    await ready;
    if (_extra.contains(i)) return;
    _extra.add(i);
    await _rns!.addInterface(i);
    _extraSubs[i] = i.stateChanges.listen((s) {
      if (s == InterfaceState.online) unawaited(announce());
    });
  }

  /// Detaches an interface added with [addInterface] (does not stop it).
  Future<void> removeInterface(RnsInterface i) async {
    if (!_extra.remove(i)) return;
    await _extraSubs.remove(i)?.cancel();
    await _rns?.transport.removeInterface(i);
  }

  /// `lora` for traffic over an RNode, `tcp` otherwise.
  static String transportOf(RnsInterface? i) =>
      i is RNodeInterface ? 'lora' : 'tcp';

  bool get _anyExtraOnline => _extra.any((i) => i.online);

  // -------------------------------------------------------------- device group

  /// Opens a pairing window: the returned host exposes the QR text
  /// (`invite.encode()`); [confirm] shows the code and asks the user.
  Future<PairingHost> startPairing({
    required Future<bool> Function(PairingRequest) confirm,
    void Function(GroupDevice)? onPaired,
  }) async {
    await ready;
    final host = await group.startPairing(
      rns,
      groupDestination: router.destination,
      confirm: confirm,
      onPaired: (d) {
        unawaited(() async {
          await startGroupRuntimeIfNeeded();
          _runtime?.sync.rememberSiblings();
          await _runtime?.sync.publishDevices();
        }());
        onPaired?.call(d);
      },
    );
    unawaited(host.announce().catchError((Object _) => false));
    return host;
  }

  /// Joins the group of the device that shows [invite]. On success this
  /// device uses the group identity G from now on: its old chats become
  /// read-only history labelled with this device's name, the old identity B
  /// is retired (kept only as the legacy bridge key until the bridge knows
  /// the device key).
  Future<void> joinGroup(
    PairingInvite invite, {
    required void Function(String code) onCode,
    required Future<bool> Function(String code) confirm,
  }) async {
    await ready;
    final result = await PairingClient.join(
      rns,
      group.deviceIdentity,
      invite,
      name: group.self.name,
      platform: platformId(),
      onCode: onCode,
      confirm: confirm,
    );
    await _adoptGroup(result.bundle);
    // the new device receives the group's existing history from the host
    await _runtime?.backfill.start(from: result.host?.id);
  }

  /// A sibling changed the address: this device moves to the new G, keeps the
  /// old chats as history and stops answering for the old G. The announcer
  /// re-announces the new G once the election ran again.
  Future<void> _adoptIdentity(IdentityChange c) async {
    if (_stopped) return;
    final fresh = await group.applyIdentity(c);
    await _swapIdentity(fresh, ratchets: c.ratchets, stamp: c.stamp);
  }

  Future<void> _adoptGroup(PairingBundle b) async {
    // unsent messages of the old identity cannot be sent as G
    final own = await repo.chats(accountIdentity: 'B');
    for (final c in own) {
      if (c.peerHash != null) {
        await cancelOutboundHashes(
          await repo.unsentHashes(c.peerHash!, 1 << 52),
        );
      }
    }
    final oldId = toHex(identity.hash);
    final bridgePaired =
        (await repo.getSetting(SettingKeys.bridgePubkey))?.isNotEmpty ?? false;
    await repo.retireOwnHistory(oldId, group.self.name);
    await group.applyJoin(b, bridgePaired: bridgePaired);
    await _swapIdentity(
      group.groupIdentity,
      ratchets: b.ratchets,
      stamp: b.stamp,
    );
  }

  /// Replaces the running router by one for [id].
  Future<void> _swapIdentity(
    Identity id, {
    List<RatchetEntry> ratchets = const [],
    Uint8List? stamp,
  }) async {
    await _stopRuntime();
    await _stopRouter();
    _identity = id;
    await _startRouter(
      id,
      group.displayName.isEmpty ? null : group.displayName,
    );
    if (ratchets.isNotEmpty) {
      await router.destination.mergeRatchets(ratchets);
    }
    if (stamp != null) {
      await rns.transport.importStamp(router.destination, stamp);
    }
    final b = bridge;
    if (b != null) {
      // the connection holds the old router: reconnect with the new one
      try {
        await b.stop();
        await b.start();
      } on Object {
        // the bridge reconnects on its own schedule
      }
    }
    await startGroupRuntimeIfNeeded();
    unawaited(announce());
  }

  /// Removes another device from the group: it stops receiving syncs and the
  /// sync key rotates. It still holds G; offer [changeAddress] afterwards.
  Future<GroupDevice?> removeDevice(String id) async {
    final rt = _runtime;
    if (rt != null) {
      final d = await rt.sync.removeDevice(id);
      if (d != null) await group.persist();
      return d;
    }
    return group.removeDevice(id);
  }

  /// "Change address": a new group identity G, announced, with an LXMF notice
  /// ("my new address is ...") from the old G to recent contacts. Old chats
  /// stay. Returns how many contacts were notified (delivery or hand-over to
  /// the network within [noticeTimeout]).
  Future<int> changeAddress({
    int maxContacts = 50,
    Duration noticeTimeout = const Duration(seconds: 30),
  }) async {
    await ready;
    final fresh = await Identity.generate();
    final oldHash = toHex(identity.hash);
    final newHex = toHex(LXMessage.deliveryHash(fresh));
    final chats = [...await repo.chats(accountIdentity: 'B')]
      ..sort((a, b) => (b.lastTs ?? 0).compareTo(a.lastTs ?? 0));
    final text = addressChangeNotice(newHex, name: group.displayName);
    final sent = <LxmOutbound>[];
    for (final c in chats) {
      final p = c.peerHash;
      if (p == null || c.kind != 'lxmf') continue;
      if (sent.length >= maxContacts) break;
      sent.add(
        await router.send(
          destinationHash: fromHex(p),
          content: text,
          method: LxmfMethod.opportunistic,
        ),
      );
    }
    var ok = 0;
    await Future.wait([
      for (final o in sent)
        o.done
            .timeout(noticeTimeout)
            .then((h) {
              if (h.state == LxmState.delivered || h.state == LxmState.sent) {
                ok++;
              }
            })
            .catchError((Object _) {}),
    ]);
    await group.replaceGroupIdentity(fresh);
    final ratchets = <RatchetEntry>[];
    await _swapIdentity(fresh);
    // move the other devices: the new key, name, ratchets and stamp (sent by
    // this device only; the notice above also went out once, from the old G)
    final rt = _runtime;
    if (rt != null) {
      ratchets.addAll(router.destination.exportRatchets());
      await rt.sync.publishIdentity(
        IdentityChange(
          privateKey: fresh.privateKey!,
          gen: group.state.identityGen,
          replaces: oldHash,
          name: group.displayName,
          nameRev: group.state.nameRev,
          ratchets: ratchets,
          stamp: await rns.transport.exportStamp(router.destination),
          timebase: group.state.timebase,
        ),
      );
    }
    return ok;
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
        final c = await repo.remoteChat(id);
        // histories of this very device (retired identity B) need no vault
        if (c?.remoteDeviceId == null ||
            !await repo.isLegacyDevice(c!.remoteDeviceId!)) {
          remote = true;
        }
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
    final deleted = await repo.deleteChats(own);
    for (final d in deleted) {
      if (d.peerHash != null) {
        unawaited(
          _runtime?.publishDelete(
                d.peerHash!,
                d.lastTsMs ?? DateTime.now().millisecondsSinceEpoch,
              ) ??
              Future<void>.value(),
        );
      }
    }
    for (final id in remote) {
      final c = await repo.remoteChat(id);
      if (c?.remoteDeviceId == null || c?.peerHash == null) continue;
      final legacy = await repo.isLegacyDevice(c!.remoteDeviceId!);
      await repo.removeVaultHistory(
        c.remoteDeviceId!,
        c.peerHash!,
        uploadDelete: !legacy || (bridge?.vault.canDeleteRemote ?? false),
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
      transport: _current == NodeConnection.online
          ? 'tcp'
          : (_anyExtraOnline ? 'lora' : 'none'),
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
    unawaited(
      _runtime?.publishMessage(
            hash: toHex(o.hash),
            peer: peer,
            incoming: false,
            text: text,
            tsMs: DateTime.now().millisecondsSinceEpoch,
            route: _routeName(o.method),
            state: MsgStatus.sent,
          ) ??
          Future<void>.value(),
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
      transport: transportOf(r.interface),
      signatureValid: m.signatureValidated,
    );
    // forward to the siblings (the receiver dedupes by message hash)
    final rt = _runtime;
    if (rt != null) {
      final ts =
          ((m.timestamp ?? DateTime.now().millisecondsSinceEpoch / 1000) * 1000)
              .round();
      await rt.publishMessage(
        hash: hash,
        peer: peerHex,
        peerName: peer?.displayName,
        incoming: true,
        text: m.contentAsString,
        title: m.title.isEmpty ? null : m.titleAsString,
        tsMs: ts,
        route: _routeName(r.method),
      );
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
      transport: onWire ? transportOf(e.interface) : null,
      error: e.error,
    );
    if (_runtime != null &&
        (status == MsgStatus.delivered || status == MsgStatus.failed)) {
      final msg = await repo.message(ob.messageId);
      final chat = msg == null ? null : await repo.chat(msg.chatId);
      if (msg != null && chat?.peerHash != null) {
        unawaited(
          _runtime!.publishMessage(
            hash: toHex(e.hash),
            peer: chat!.peerHash!,
            incoming: false,
            text: msg.text,
            tsMs: msg.ts,
            state: status,
          ),
        );
      }
    }
    // The creation of the outbox row already logged "queued".
    if (e.stage != 'queued') {
      await repo.addLog(ob.messageId, e.stage, detail: e.error, at: e.at);
    }
  }

  // ---------------------------------------------------------------- lifecycle

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _bridgeStatusSub?.cancel();
    await _ifaceSub?.cancel();
    for (final s in _extraSubs.values) {
      await s.cancel();
    }
    for (final s in [..._subs, ..._routerSubs]) {
      await s.cancel();
    }
    await _stopRuntime();
    await _router?.stop();
    await _rns?.stop();
    await _connection.close();
  }
}
