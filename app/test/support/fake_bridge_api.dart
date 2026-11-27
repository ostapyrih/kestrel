import 'dart:async';

import 'package:kestrel/bridge/bridge_connection.dart';
import 'package:kestrel/bridge/codec.dart';

typedef Handler = FutureOr<Map<String, Object?>> Function(
  Map<String, Object?> args,
);

/// A scripted [BridgeApi]: records every call, answers from [handlers].
class FakeBridgeApi implements BridgeApi {
  final Map<String, Handler> handlers = {};
  final List<(String, Map<String, Object?>)> calls = [];
  final Map<String, Duration?> timeouts = {};
  final _status = StreamController<BridgeStatus>.broadcast();
  final _pushes = StreamController<PushEvent>.broadcast();
  final _connected = StreamController<HelloResult>.broadcast();
  BridgeStatus _s = const BridgeStatus(BridgeState.connecting);
  bool up = false;
  bool fallback = false;
  bool revokedMarked = false;
  String? infoName;
  String? infoPlatform;
  Map<String, Object?>? redeemed;
  Object? redeemError;
  @override
  bool fastRetry = false;
  int retries = 0;

  FakeBridgeApi({bool vaultStubs = true}) {
    if (!vaultStubs) return;
    // an idle vault nobody activated: tests that do not care about the
    // vault never see it fail
    handlers['/vault/key'] = (a) => {
      'key_epoch': 1,
      'in_use': false,
      'wrapped_epoch': null,
      'wrapped_group_key': null,
      'wrap': null,
    };
    handlers['/vault/set_keys'] = (a) => {'key_epoch': 1};
    handlers['/vault/list'] = (a) => {
      'blobs': <Object?>[],
      'cursor': 0,
      'more': false,
      'key_epoch': 1,
    };
  }

  @override
  BridgeStatus get status => _s;
  @override
  Stream<BridgeStatus> get statusChanges => _status.stream;
  @override
  Stream<PushEvent> get pushes => _pushes.stream;
  @override
  Stream<HelloResult> get connected => _connected.stream;
  @override
  bool get linkUp => up;
  @override
  bool get canFallback => fallback;

  @override
  void setIdentityInfo(String name, String platform) {
    infoName = name;
    infoPlatform = platform;
  }

  @override
  Future<Map<String, Object?>> redeem({
    required List<int> token,
    required String name,
    required String platform,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final e = redeemError;
    if (e != null) throw e;
    redeemed = {'token': token, 'name': name, 'platform': platform};
    return handlers['/devices/redeem']?.call(redeemed!) ??
        {
          'device': {
            'device_id': 'ee' * 16,
            'public_key': 'ab' * 64,
            'name': name,
            'platform': platform,
            'roles': <String>[],
            'bootstrap': false,
            'added_by': 'dd' * 16,
            'added_at': 1.0,
          },
        };
  }

  List<Map<String, Object?>> callsTo(String path) => [
    for (final c in calls)
      if (c.$1 == path) c.$2,
  ];

  void setState(BridgeState st) {
    _s = BridgeStatus(st, fallback: fallback);
    _status.add(_s);
  }

  /// The link came up: emits the connected event like the real connection.
  void connect(HelloResult hello) {
    up = true;
    _s = BridgeStatus(BridgeState.connected, hello: hello);
    _status.add(_s);
    _connected.add(hello);
  }

  void disconnect() {
    up = false;
    setState(BridgeState.unreachable);
  }

  void push(
    String event,
    Map<String, Object?> data, {
    String? id,
    int seq = 1,
  }) => _pushes.add(
    PushEvent(seq: seq, id: id ?? 'ev$seq', ts: 0, event: event, data: data),
  );

  @override
  Future<Map<String, Object?>> call(
    String path,
    Map<String, Object?> args, {
    Duration? timeout,
  }) async {
    if (!up && !fallback) throw BridgeTransportError('bridge unreachable');
    calls.add((path, args));
    timeouts[path] = timeout;
    final h = handlers[path];
    if (h == null) throw BridgeError('unknown_path', path);
    return h(args);
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    await _status.close();
    await _pushes.close();
    await _connected.close();
  }

  @override
  void retryNow() => retries++;

  @override
  void markRevoked() {
    revokedMarked = true;
    setState(BridgeState.revoked);
  }
}

Map<String, Object?> deviceMap(
  String id, {
  String name = 'dev',
  List<String> roles = const [],
  bool bootstrap = false,
  double? revokedAt,
}) => {
  'device_id': id,
  'public_key': 'ab' * 64,
  'name': name,
  'platform': 'linux',
  'roles': roles,
  'bootstrap': bootstrap,
  'added_by': 'config',
  'added_at': 1.0,
  'last_seen': 2.0,
  'revoked_at': revokedAt,
};

HelloResult helloFor(
  String deviceId, {
  String stateId = 'state1',
  bool vaultInUse = false,
  List<String> roles = const [],
  List<String> capabilities = const ['lxmf', 'rrc'],
}) => HelloResult.fromMap({
  'protocol_version': 2,
  'min_protocol_version': 2,
  'max_protocol_version': 2,
  'server': 'kestrel-bridge/0.3.0',
  'time': 1700000000.0,
  'state_id': stateId,
  'cursor': 0,
  'device': deviceMap(deviceId, name: 'This', roles: roles, bootstrap: true),
  'capabilities': capabilities,
  'compat': {'ok': true, 'meshchatx_version': '4.12.0', 'api_version': 1},
  'vault': {'key_epoch': 1, 'in_use': vaultInUse, 'used_bytes': 0},
  'limits': {},
});

Map<String, Object?> convMap(
  String peer, {
  String name = 'Peer',
  bool unread = false,
  int lastId = 1,
}) => {
  'peer': peer,
  'name': name,
  'last_ts': 'x',
  'unread': unread,
  'failed': 0,
  'preview': 'p',
  'last_id': lastId,
};

Map<String, Object?> msgMap(
  int id,
  String hash, {
  bool incoming = true,
  String state = 'delivered',
  String text = 'hi',
  double ts = 1700000000,
  String? origin,
  String? cmdId,
  String? method = 'direct',
}) => {
  'id': id,
  'hash': hash,
  'incoming': incoming,
  'state': state,
  'method': method,
  'title': '',
  'text': text,
  'ts': ts,
  'attachments': false,
  'origin_device': origin,
  'cmd_id': cmdId,
};
