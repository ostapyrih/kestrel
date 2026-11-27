import 'dart:async';
import 'dart:typed_data';

import '../destination.dart';
import '../identity.dart';
import '../msgpack/msgpack.dart';
import '../reticulum.dart';
import '../util.dart';
import 'group_state.dart';

/// What a device knows about a sibling from its presence packets.
class SiblingInfo {
  SiblingInfo({
    required this.id,
    required this.heardAt,
    required this.wall,
    required this.heardWall,
    required this.internet,
    required this.announcing,
  });
  final String id;

  /// Local monotonic-ish receive time (unix seconds).
  final int heardAt;

  /// The sibling's own wall clock at sending, unix seconds.
  final int wall;

  /// Our wall clock when we received it.
  final int heardWall;
  final bool internet;
  final bool announcing;

  /// How far the sibling's clock is ahead of ours (negative = behind).
  int get offset => wall - heardWall;
}

/// Announcer election (docs/device-sync.md): pure and deterministic.
///
/// Candidates are the devices heard within the window plus this device.
/// A candidate whose clock is ahead of the group median by more than
/// [clockTolerance] is excluded (an early clock would push the announce
/// timebase into the future and block every takeover). Among the rest,
/// devices with an internet (TCP) path come before LoRa-only ones, then the
/// lowest device id wins.
String electAnnouncer({
  required String self,
  required bool selfInternet,
  required Map<String, SiblingInfo> alive,
  int clockTolerance = 30,
}) {
  final offsets = <String, int>{
    self: 0,
    for (final e in alive.entries) e.key: e.value.offset,
  };
  final sorted = offsets.values.toList()..sort();
  final median = sorted[sorted.length ~/ 2];
  bool eligible(String id) => offsets[id]! <= median + clockTolerance;
  final cands = <({String id, bool net})>[
    (id: self, net: selfInternet),
    for (final e in alive.entries) (id: e.key, net: e.value.internet),
  ].where((c) => eligible(c.id)).toList();
  if (cands.isEmpty) return self;
  cands.sort((a, b) {
    if (a.net != b.net) return a.net ? -1 : 1;
    return a.id.compareTo(b.id);
  });
  return cands.first.id;
}

/// Presence + announcer role of one device.
///
/// Presence packets (signed by the device key, encrypted to the sibling's
/// presence destination) go to every sibling every [interval]; a sibling not
/// heard for [deadAfter] is out. The elected device announces G; the others
/// are held silent. Handover is make-before-break: a newly elected device
/// starts announcing at once and the previous announcer steps down only after
/// it sees the new one announcing. A device that hears nobody announces
/// itself.
class GroupAnnouncer {
  GroupAnnouncer({
    required this.rns,
    required this.deviceKey,
    required this.state,
    required this.internet,
    required this.onRole,
    this.interval = const Duration(seconds: 10),
    this.deadAfter = const Duration(seconds: 35),
    this.clockTolerance = 30,
    this.startupGrace,
    this.reannounceGap = const Duration(seconds: 5),
    this.clock,
  });

  static const String app = 'kestrel';
  static const List<String> aspects = ['group', 'presence'];

  final Reticulum rns;
  final Identity deviceKey;
  final GroupState state;

  /// True while this device has an internet (TCP) path, false when it only
  /// reaches the network over LoRa or nothing.
  final bool Function() internet;

  /// Called when the role changes: true = announce G, answer path requests
  /// for it and sync its inbox; false = silent. Announce immediately when it
  /// turns true.
  final FutureOr<void> Function(bool announcing) onRole;
  final Duration interval;
  final Duration deadAfter;
  final int clockTolerance;

  /// A device that knows siblings waits this long (default 2 intervals)
  /// before it promotes itself because it has not heard anyone yet.
  final Duration? startupGrace;

  /// Minimum time between conflict re-announces.
  final Duration reannounceGap;

  /// Wall clock in unix seconds (tests simulate skew).
  int Function()? clock;

  late final Destination presence;
  final Map<String, SiblingInfo> _seen = {};
  Timer? _timer;
  bool _announcing = false;
  bool _started = false;
  late DateTime _startedAt;
  DateTime? _lastReannounce;

  String get ownId => toHex(deviceKey.hash);
  bool get isAnnouncer => _announcing;

  int _now() =>
      (clock ?? () => DateTime.now().millisecondsSinceEpoch ~/ 1000)();

  /// Siblings currently considered alive.
  Map<String, SiblingInfo> get alive {
    final now = _now();
    return {
      for (final e in _seen.entries)
        if (state.devices.isActive(e.key) &&
            now - e.value.heardAt <= deadAfter.inSeconds)
          e.key: e.value,
    };
  }

  /// The currently elected announcer (what [evaluate] acts on).
  String get elected => electAnnouncer(
        self: ownId,
        selfInternet: internet(),
        alive: alive,
        clockTolerance: clockTolerance,
      );

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _startedAt = DateTime.now();
    presence = await rns.createDestination(deviceKey, app, aspects);
    presence.onPacket = (data, _) => _onPacket(data);
    _timer = Timer.periodic(interval, (_) => tick());
    await tick();
  }

  Future<void> stop() async {
    _started = false;
    _timer?.cancel();
    rns.transport.deregisterDestination(presence);
  }

  /// Announces the presence destination so siblings can find a path to it
  /// (once per connection; the stamp is generated once).
  Future<bool> announcePresence() => rns.announce(presence);

  /// One round: send presence, then decide the role.
  Future<void> tick() async {
    await sendPresence();
    await evaluate();
  }

  Future<void> sendPresence() async {
    final body = packb({
      'v': 1,
      'dev': ownId,
      't': _now(),
      'net': internet(),
      'ann': _announcing,
      'ep': state.epoch,
    });
    final sig = await deviceKey.sign(body);
    final packet = packb([body, sig]);
    for (final d in state.devices.active) {
      if (d.id == ownId) continue;
      final h = rns.rememberDestination(d.publicKey, app, aspects);
      final dest = rns.recallDestination(h, app, aspects);
      if (dest == null) continue;
      try {
        await rns.transport.sendData(dest, packet, createReceipt: false);
      } on Object {
        // best effort
      }
    }
  }

  void _onPacket(Uint8List data) {
    unawaited(_handle(data));
  }

  Future<void> _handle(Uint8List data) async {
    try {
      final o = unpackb(data);
      if (o is! List ||
          o.length != 2 ||
          o[0] is! Uint8List ||
          o[1] is! Uint8List) {
        return;
      }
      final body = o[0] as Uint8List;
      final b = unpackb(body);
      if (b is! Map || b['v'] != 1 || b['dev'] is! String || b['t'] is! int) {
        return;
      }
      final id = b['dev']! as String;
      final dev = state.devices[id];
      if (dev == null || dev.removed || id == ownId) return;
      final pub = Identity.fromPublicKey(dev.publicKey);
      if (!await pub.validate(o[1] as Uint8List, body)) return;
      _seen[id] = SiblingInfo(
        id: id,
        heardAt: _now(),
        wall: b['t']! as int,
        heardWall: _now(),
        internet: b['net'] == true,
        announcing: b['ann'] == true,
      );
      await evaluate();
    } on Object {
      // ignore malformed presence
    }
  }

  /// Decides the role from what is known now.
  Future<void> evaluate() async {
    final e = elected;
    if (e == ownId) {
      if (_announcing) {
        // A sibling announces too (it was promoted before it heard us, or it
        // is a handover in progress): its announce may now hold the path, so
        // announce again. The monotonic timebase makes ours the newest.
        final conflict = alive.values.any((i) => i.announcing);
        final now = DateTime.now();
        if (conflict &&
            (_lastReannounce == null ||
                now.difference(_lastReannounce!) >= reannounceGap)) {
          _lastReannounce = now;
          await onRole(true);
        }
      }
      if (!_announcing) {
        final grace = startupGrace ?? interval * 2;
        final waiting = state.devices.active.length > 1 &&
            alive.isEmpty &&
            DateTime.now().difference(_startedAt) < grace;
        if (!waiting) await _setRole(true);
      }
      return;
    }
    if (_announcing) {
      // make-before-break: step down once the elected device announces
      final other = alive[e];
      if (other != null && other.announcing) await _setRole(false);
    }
  }

  Future<void> _setRole(bool on) async {
    _announcing = on;
    await onRole(on);
  }
}
