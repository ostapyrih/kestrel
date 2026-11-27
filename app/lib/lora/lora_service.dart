import 'dart:async';

import 'package:kestrel_rns/kestrel_rns.dart';

import '../node/node_service.dart';
import 'lora_model.dart';
import 'lora_transports.dart';

/// What the LoRa settings page shows.
class LoraView {
  const LoraView({required this.settings, this.status, this.starting = false});

  final LoraSettings settings;

  /// Null while no interface exists (disabled / not configured).
  final RNodeStatus? status;
  final bool starting;

  InterfaceState get state => status?.state ?? InterfaceState.offline;
  bool get connected => state == InterfaceState.online;
}

/// What the settings page needs from the service (faked in widget tests).
abstract class LoraController {
  LoraView get view;
  Stream<LoraView> get changes;
  Set<LoraKind> get supportedKinds;
  Stream<List<LoraDevice>> scanBle();
  List<LoraDevice> listUsb();

  /// Persists and applies new settings.
  Future<void> update(LoraSettings next);
}

/// Owns the RNode interface: creates it from the stored settings, attaches
/// it to the node next to the TCP interface, reconfigures the radio live
/// when parameters change, reconnects automatically (the interface retries
/// every few seconds) and switches the radio off on disconnect/exit.
class LoraService implements LoraController {
  LoraService({
    required this.store,
    required this.node,
    required this.transports,
  });

  final LoraStore store;
  final NodeService node;
  final LoraTransports transports;

  LoraSettings _settings = const LoraSettings();
  RNodeInterface? _iface;
  StreamSubscription<RNodeStatus>? _sub;
  final _changes = StreamController<LoraView>.broadcast();
  Future<void> _tail = Future.value();
  bool _stopped = false;

  @override
  Set<LoraKind> get supportedKinds => transports.supported;
  @override
  Stream<List<LoraDevice>> scanBle() => transports.scanBle();
  @override
  List<LoraDevice> listUsb() => transports.listUsb();

  LoraSettings get settings => _settings;
  RNodeInterface? get iface => _iface;
  @override
  LoraView get view => LoraView(
    settings: _settings,
    status: _iface?.status,
    starting: _iface != null && !_iface!.online && _iface!.status.error == null,
  );
  @override
  Stream<LoraView> get changes => _changes.stream;

  void _emit() {
    if (!_changes.isClosed) _changes.add(view);
  }

  /// Loads the stored settings and connects if the interface is enabled.
  Future<void> start() => _serial(() async {
    _settings = await store.load();
    await _apply(null);
  });

  /// Persists [next] and applies it: connects, disconnects, reconnects (other
  /// device) or reconfigures the radio in place (changed parameters).
  @override
  Future<void> update(LoraSettings next) => _serial(() async {
    final prev = _settings;
    _settings = next;
    await store.save(next);
    await _apply(prev);
  });

  Future<void> _serial(Future<void> Function() f) =>
      _tail = _tail.then((_) => f()).catchError((Object _) {});

  Future<void> _apply(LoraSettings? prev) async {
    if (_stopped) return;
    final s = _settings;
    final want =
        s.enabled &&
        s.hasDevice &&
        s.regulationsAcknowledged &&
        s.config.isValid;
    final sameDevice =
        prev != null &&
        prev.kind == s.kind &&
        prev.deviceId == s.deviceId &&
        prev.deviceName == s.deviceName;
    if (!want) {
      await _disconnect();
    } else if (_iface == null || !sameDevice) {
      await _disconnect();
      await _connect();
    } else if (prev.config != s.config) {
      await _iface!.reconfigure(s.config);
    }
    _emit();
  }

  Future<void> _connect() async {
    final s = _settings;
    final kind = s.kind!;
    final id = s.deviceId!;
    final name = s.deviceName ?? id;
    final i = RNodeInterface(
      label: name,
      opener: () => transports.open(kind, id, name),
      config: s.config,
      timing: transports.timing(kind),
    );
    _iface = i;
    _sub = i.statusChanges.listen((_) => _emit());
    await node.addInterface(i);
  }

  Future<void> _disconnect() async {
    final i = _iface;
    if (i == null) return;
    _iface = null;
    await _sub?.cancel();
    _sub = null;
    await node.removeInterface(i);
    await i.stop(); // radio off, "leave", close the port
  }

  /// Switches the radio off (app exit).
  Future<void> stop() async {
    _stopped = true;
    await _tail;
    await _disconnect();
    await _changes.close();
  }
}
