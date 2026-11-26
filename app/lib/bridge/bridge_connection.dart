import 'dart:async';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';

import 'codec.dart';

/// State of the connection to the bridge (shown next to the TCP indicator).
enum BridgeState {
  /// Bridge mode is off or not configured.
  off,
  connecting,
  connected,

  /// No Link (no path, bridge down, MeshChatX down...). Retrying.
  unreachable,

  /// The bridge does not accept this key (`kestrel.reject unauthorized`, or
  /// an older bridge closing the Link right after `identify()`): not paired
  /// or revoked. Retrying slowly.
  rejected,

  /// `kestrel.reject unauthorized` while pairing: this device is waiting for
  /// a trusted device to approve it. Retrying every few seconds.
  awaitingApproval,

  /// The bridge said `device_revoked` (`kestrel.reject` or an error): stopped.
  revoked,

  /// `protocol_mismatch`: stopped; the user has to update the app or bridge.
  mismatch,
}

class BridgeStatus {
  const BridgeStatus(
    this.state, {
    this.detail,
    this.fallback = false,
    this.hello,
    this.mismatch,
  });

  final BridgeState state;
  final String? detail;

  /// The LXMF fallback can carry commands while there is no Link.
  final bool fallback;
  final HelloResult? hello;

  /// Versions of `protocol_mismatch` (server/min/max/client).
  final Map<String, Object?>? mismatch;

  bool get connected => state == BridgeState.connected;

  @override
  bool operator ==(Object other) =>
      other is BridgeStatus &&
      other.state == state &&
      other.detail == detail &&
      other.fallback == fallback;

  @override
  int get hashCode => Object.hash(state, detail, fallback);
}

/// What the rest of the app needs from the bridge connection; tests replace
/// it with a scripted fake.
abstract class BridgeApi {
  BridgeStatus get status;
  Stream<BridgeStatus> get statusChanges;
  Stream<PushEvent> get pushes;

  /// Emits after every successful (re)connect (`/hello` + `/subscribe` done).
  Stream<HelloResult> get connected;

  /// True when a Link is established and identified.
  bool get linkUp;

  /// True if commands can go out as LXMF while there is no Link.
  bool get canFallback;

  /// Sends the request and returns `result`; throws [BridgeError] for an
  /// error response and [BridgeTransportError] when no response arrived.
  Future<Map<String, Object?>> call(
    String path,
    Map<String, Object?> args, {
    Duration? timeout,
  });

  Future<void> start();
  Future<void> stop();

  /// Skips the current back-off wait (new network, user action).
  void retryNow();

  /// Pairing mode: retry every few seconds instead of backing off.
  bool get fastRetry;
  set fastRetry(bool v);

  /// The bridge said this device was revoked: stop for good.
  void markRevoked();

  /// The device name and platform this device reports in every `/hello`
  /// (the app owns the device name, spec 6.1).
  void setIdentityInfo(String name, String platform);

  /// New device joining through an invite (spec 5.4): starts the connection
  /// if needed, calls `/devices/redeem` right after `identify()` and returns
  /// the device record map. Throws [BridgeError] when the bridge refuses the
  /// invite and [BridgeTransportError] when the bridge cannot be reached in
  /// [timeout].
  Future<Map<String, Object?>> redeem({
    required List<int> token,
    required String name,
    required String platform,
    Duration timeout = const Duration(seconds: 60),
  });
}

/// A `kestrel.reject` packet arrived on the Link (internal control flow).
class BridgeRejected implements Exception {
  BridgeRejected(this.packet);
  final RejectPacket packet;

  @override
  String toString() => 'BridgeRejected(${packet.code})';
}

typedef AllowFallback = bool Function();

/// Link based connection with reconnect/back-off, keepalive, push reception
/// (packets and Resources) and the LXMF command fallback.
class BridgeConnection implements BridgeApi {
  BridgeConnection({
    required this.rns,
    required this.identity,
    required List<int> bridgePublicKey,
    this.router,
    AllowFallback? allowFallback,
    this.clientName = 'kestrel-app',
    this.fastRetry = false,
    this.retryMin = const Duration(seconds: 2),
    this.retryMax = const Duration(seconds: 60),
    this.rejectedRetry = const Duration(seconds: 30),
    this.keepaliveEvery = const Duration(seconds: 90),
    this.linkTimeout = const Duration(seconds: 25),
    this.requestTimeout = const Duration(seconds: 30),
    this.lxmfTimeout = const Duration(minutes: 3),
    this.pathTimeout = const Duration(seconds: 15),
    double Function()? clock,
  }) : bridgePublicKey = Uint8List.fromList(bridgePublicKey),
       _allowFallback = allowFallback ?? (() => false),
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch / 1000);

  final Reticulum rns;
  final Identity identity;
  final Uint8List bridgePublicKey;
  final LxmRouter? router;
  final String clientName;

  @override
  bool fastRetry;
  final Duration retryMin;
  final Duration retryMax;
  final Duration rejectedRetry;
  final Duration keepaliveEvery;
  final Duration linkTimeout;
  final Duration requestTimeout;
  final Duration lxmfTimeout;
  final Duration pathTimeout;
  final AllowFallback _allowFallback;
  final double Function() _clock;

  late final Destination _dest = Destination.single(
    Identity.fromPublicKey(bridgePublicKey),
    'kestrel',
    const ['bridge'],
    direction: DestinationDirection.outbound,
  );
  late final Uint8List _lxmfHash = bridgeLxmfHash(bridgePublicKey);

  final _status = StreamController<BridgeStatus>.broadcast();
  final _pushes = StreamController<PushEvent>.broadcast();
  final _connected = StreamController<HelloResult>.broadcast();
  BridgeStatus _current = const BridgeStatus(BridgeState.off);
  Link? _link;
  bool _running = false;
  bool _terminal = false;
  int _rejectedStreak = 0;
  double _clockOffset = 0;
  Completer<void>? _wake;
  final Map<String, Completer<Map<String, Object?>>> _lxmfPending = {};
  String? _deviceName;
  String? _platform;
  Map<String, Object?>? _redeemArgs;
  Completer<Map<String, Object?>>? _redeemDone;

  @override
  BridgeStatus get status => _current;
  @override
  Stream<BridgeStatus> get statusChanges => _status.stream;
  @override
  Stream<PushEvent> get pushes => _pushes.stream;
  @override
  Stream<HelloResult> get connected => _connected.stream;
  @override
  bool get linkUp => _link != null && _link!.isActive && _current.connected;
  @override
  bool get canFallback => router != null && _allowFallback();

  /// Bridge clock minus local clock, from the last `/hello`.
  double get clockOffset => _clockOffset;

  void _set(
    BridgeState s, {
    String? detail,
    HelloResult? hello,
    Map<String, Object?>? mismatch,
  }) {
    final n = BridgeStatus(
      s,
      detail: detail,
      fallback: canFallback,
      hello: hello ?? _current.hello,
      mismatch: mismatch,
    );
    final changed = n != _current;
    _current = n;
    if (changed && !_status.isClosed) _status.add(n);
  }

  // ------------------------------------------------------------- lifecycle

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _terminal = false;
    unawaited(_run());
  }

  @override
  Future<void> stop() async {
    _running = false;
    _wake?.complete();
    final l = _link;
    _link = null;
    try {
      await l?.teardown();
    } on Object {
      // closing anyway
    }
    for (final c in _lxmfPending.values) {
      if (!c.isCompleted) {
        c.completeError(BridgeTransportError('bridge connection stopped'));
      }
    }
    _lxmfPending.clear();
    _set(BridgeState.off);
    await _status.close();
    await _pushes.close();
    await _connected.close();
  }

  @override
  void retryNow() {
    final w = _wake;
    if (w != null && !w.isCompleted) w.complete();
  }

  @override
  void setIdentityInfo(String name, String platform) {
    _deviceName = name;
    _platform = platform;
  }

  @override
  Future<Map<String, Object?>> redeem({
    required List<int> token,
    required String name,
    required String platform,
    Duration timeout = const Duration(seconds: 60),
  }) {
    final done = Completer<Map<String, Object?>>();
    _redeemDone = done;
    _redeemArgs = {
      'token': Uint8List.fromList(token),
      'name': name,
      'platform': platform,
    };
    _deviceName = name;
    _platform = platform;
    if (!_running) {
      unawaited(start());
    } else {
      retryNow();
    }
    return done.future.timeout(
      timeout,
      onTimeout: () {
        _redeemArgs = null;
        _redeemDone = null;
        throw BridgeTransportError('the bridge did not answer');
      },
    );
  }

  @override
  void markRevoked() {
    _terminal = true;
    _set(BridgeState.revoked, detail: 'device_revoked');
    _link?.teardown();
  }

  Future<void> _sleep(Duration d) {
    final w = _wake = Completer<void>();
    return Future.any([Future<void>.delayed(d), w.future]);
  }

  Future<void> _run() async {
    var backoff = retryMin;
    while (_running && !_terminal) {
      _set(BridgeState.connecting);
      var wait = backoff;
      try {
        await _session(() => backoff = retryMin);
        wait = fastRetry ? retryMin : backoff;
      } on BridgeError catch (e) {
        if (e.code == 'protocol_mismatch') {
          _terminal = true;
          _set(BridgeState.mismatch, detail: e.message, mismatch: e.details);
          return;
        }
        if (e.code == 'device_revoked') {
          _terminal = true;
          _set(BridgeState.revoked, detail: e.code);
          return;
        }
        _set(BridgeState.unreachable, detail: e.code);
        backoff = _grow(backoff);
        wait = fastRetry ? retryMin : backoff;
      } on BridgeRejected catch (e) {
        if (e.packet.isRevoked) {
          _terminal = true;
          _set(BridgeState.revoked, detail: e.packet.code);
          return;
        }
        _set(
          fastRetry ? BridgeState.awaitingApproval : BridgeState.rejected,
          detail: e.packet.code,
        );
        wait = fastRetry ? retryMin : rejectedRetry;
      } on BridgeTransportError catch (e) {
        if (e.rejected) {
          _rejectedStreak++;
          if (_rejectedStreak >= 2) {
            _set(BridgeState.rejected, detail: e.message);
            wait = fastRetry ? retryMin : rejectedRetry;
          } else {
            _set(BridgeState.unreachable, detail: e.message);
            wait = retryMin;
          }
        } else {
          _set(BridgeState.unreachable, detail: e.message);
          backoff = _grow(backoff);
          wait = fastRetry ? retryMin : backoff;
        }
      } on Object catch (e) {
        _set(BridgeState.unreachable, detail: '$e');
        backoff = _grow(backoff);
        wait = fastRetry ? retryMin : backoff;
      }
      if (!_running || _terminal) break;
      await _sleep(wait);
    }
  }

  Duration _grow(Duration d) {
    final n = d * 2;
    return n > retryMax ? retryMax : n;
  }

  /// One Link from establishment until it closes. Throws if it could not be
  /// brought up; returns when an established Link ended.
  Future<void> _session(void Function() onSuccess) async {
    final until = DateTime.now().add(const Duration(seconds: 30));
    while (!rns.interfaces.any((i) => i.online)) {
      if (!_running) return;
      if (DateTime.now().isAfter(until)) {
        throw BridgeTransportError('no network');
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (!await rns.awaitPath(_dest.hash, timeout: pathTimeout)) {
      throw BridgeTransportError('no path to the bridge');
    }
    final link = await Link.initiate(rns.transport, _dest);
    try {
      await link.established.timeout(linkTimeout);
    } on Object {
      unawaited(link.teardown());
      throw BridgeTransportError('link not established');
    }
    var reject = Completer<RejectPacket>();
    link
      ..resourceStrategy = ResourceStrategy.all
      ..onPacket = (data, _) {
        final r = RejectPacket.tryParse(_tryUnpack(data));
        if (r != null) {
          if (!reject.isCompleted) reject.complete(r);
          return;
        }
        _onPushBytes(data);
      }
      ..onResourceConcluded = (r) {
        if (r.status == ResourceStatus.complete && r.data != null) {
          _onPushBytes(r.data!);
        }
      };
    _link = link;
    try {
      await link.identify(identity);
      if (_redeemArgs != null) {
        await _redeemOn(link);
        // the reject packet that preceded the redeem is obsolete: this Link
        // is trusted now
        reject = Completer<RejectPacket>();
      }
      final helloReq = _request(
        link,
        '/hello',
        {
          'protocol_version': bridgeProtocolVersion,
          'client': clientName,
          if (_deviceName != null) 'name': _deviceName,
          if (_platform != null) 'platform': _platform,
        },
        null,
        expectIdentify: true,
      );
      // the reason packet (sent right after identify) wins over the
      // `unauthorized` response or the closed Link that follow it
      final first = await Future.any<Object>([
        helloReq.then<Object>((v) => v, onError: (Object e) => e),
        reject.future,
      ]);
      if (first is RejectPacket) {
        unawaited(helloReq.then<void>((_) {}, onError: (Object _) {}));
        _clockOffset = (first.serverTime ?? _clock()) - _clock();
        throw BridgeRejected(first);
      }
      if (first is BridgeTransportError || first is BridgeError) {
        // an older bridge, or the packet is still on its way: give it a moment
        final r = await reject.future.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () => const RejectPacket('', null),
        );
        if (r.code.isNotEmpty) throw BridgeRejected(r);
        if (first is BridgeError) throw first;
        throw first as BridgeTransportError;
      }
      final hello = first as Map<String, Object?>;
      final h = HelloResult.fromMap(hello);
      _clockOffset = h.time - _clock();
      await _request(link, '/subscribe', {
        'topics': ['lxmf', 'rrc'],
        'profile': 'full',
      }, null);
      _rejectedStreak = 0;
      onSuccess();
      _set(BridgeState.connected, hello: h);
      if (!_connected.isClosed) _connected.add(h);
      // keepalive: the Link has its own, this also detects a dead bridge
      final ka = Timer.periodic(keepaliveEvery, (_) async {
        try {
          await _request(link, '/hello', {
            'protocol_version': bridgeProtocolVersion,
          }, const Duration(seconds: 20));
        } on BridgeError {
          // answered: alive
        } on Object {
          unawaited(link.teardown());
        }
      });
      try {
        await link.closed;
      } finally {
        ka.cancel();
      }
      if (_running && !_terminal) {
        _set(BridgeState.unreachable, detail: 'link closed');
      }
    } finally {
      if (identical(_link, link)) _link = null;
      unawaited(link.teardown());
    }
  }

  /// `/devices/redeem` on the fresh Link (spec 5.4). The `kestrel.reject`
  /// packet that precedes it is ignored here; on success the same Link is a
  /// trusted Link and the session carries on with `/hello`.
  Future<void> _redeemOn(Link link) async {
    final args = _redeemArgs!;
    final done = _redeemDone;
    try {
      final res = await _request(link, '/devices/redeem', args, null);
      _redeemArgs = null;
      _redeemDone = null;
      if (done != null && !done.isCompleted) done.complete(res);
    } on BridgeError catch (e) {
      // the bridge said no (invalid / expired / used / vault ...): final
      _redeemArgs = null;
      _redeemDone = null;
      if (done != null && !done.isCompleted) done.completeError(e);
      rethrow;
    }
  }

  void _onPushBytes(List<int> data) {
    final ev = PushEvent.tryParse(_tryUnpack(data));
    if (ev != null && !_pushes.isClosed) _pushes.add(ev);
  }

  static Object? _tryUnpack(List<int> d) {
    try {
      return unpackb(d);
    } on Object {
      return null;
    }
  }

  // -------------------------------------------------------------- requests

  Future<Map<String, Object?>> _request(
    Link link,
    String path,
    Map<String, Object?> args,
    Duration? timeout, {
    bool expectIdentify = false,
  }) async {
    final to = timeout ?? requestTimeout;
    final rr = await link.request(
      path,
      data: args,
      timeout: to.inMilliseconds / 1000,
    );
    if (rr == null) throw BridgeTransportError('request not sent');
    final res = await Future.any<Object?>([
      rr.done,
      link.closed.then((_) => null),
    ]);
    if (res == null) {
      throw BridgeTransportError(
        'link closed',
        rejected:
            expectIdentify &&
            link.teardownReason == TeardownReason.destinationClosed,
      );
    }
    if (rr.status != RequestStatus.ready) {
      throw BridgeTransportError('request timed out');
    }
    return parseResponse(rr.response);
  }

  /// `{"ok": true, "result"}` -> result; `{"ok": false, "error"}` -> throws.
  static Map<String, Object?> parseResponse(Object? resp) {
    if (resp is! Map) throw BridgeTransportError('empty response');
    final m = asMap(resp);
    if (m['ok'] == true) {
      return m['result'] is Map ? asMap(m['result']) : <String, Object?>{};
    }
    throw BridgeError.fromMap(m['error']);
  }

  static bool lxmfAllowed(String path) =>
      path != '/subscribe' &&
      !path.startsWith('/devices/') &&
      !path.startsWith('/vault/');

  @override
  Future<Map<String, Object?>> call(
    String path,
    Map<String, Object?> args, {
    Duration? timeout,
  }) async {
    final link = _link;
    if (link != null && linkUp) {
      return _request(link, path, args, timeout);
    }
    if (canFallback && lxmfAllowed(path)) {
      return _callLxmf(path, args, timeout ?? lxmfTimeout);
    }
    throw BridgeTransportError('bridge unreachable');
  }

  // ---------------------------------------------------------- LXMF fallback

  Future<Map<String, Object?>> _callLxmf(
    String path,
    Map<String, Object?> args,
    Duration timeout,
  ) async {
    final r = router!;
    rns.rememberDestination(bridgePublicKey, 'lxmf', const ['delivery']);
    final cmdId = (args['cmd_id'] as String?) ?? newCmdId();
    final existing = _lxmfPending[cmdId];
    final c = existing ?? Completer<Map<String, Object?>>();
    if (existing == null) {
      _lxmfPending[cmdId] = c;
      final body = encodeLxmfCommand(
        cmdId: cmdId,
        ts: _clock() + _clockOffset,
        path: path,
        args: args,
      );
      await r.send(
        destinationHash: _lxmfHash,
        content: '',
        fields: lxmfCommandFields(body),
        method: LxmfMethod.opportunistic,
      );
    }
    try {
      return await c.future.timeout(
        timeout,
        onTimeout: () => throw BridgeTransportError('no LXMF response'),
      );
    } finally {
      if (identical(_lxmfPending[cmdId], c)) _lxmfPending.remove(cmdId);
    }
  }

  /// Offers an LXMF message from the router; true if it came from the bridge
  /// (a `kestrel.resp` / `kestrel.push` or anything else from S) and was
  /// consumed, so that it never appears as a chat message.
  bool handleLxmf(LXMessage m) {
    if (toHex(m.sourceHash) != toHex(_lxmfHash)) return false;
    if (!m.signatureValidated) return true; // from S's address but unverified
    final env = decodeLxmfEnvelope(m.fields);
    if (env == null) return true;
    if (env.isPush) {
      final ev = PushEvent.tryParse(env.payload);
      if (ev != null && !_pushes.isClosed) _pushes.add(ev);
    } else if (env.isResponse) {
      final id = env.payload['cmd_id'];
      final c = id is String ? _lxmfPending[id] : null;
      if (c != null && !c.isCompleted) {
        try {
          c.complete(parseResponse(env.payload));
        } on Object catch (e) {
          c.completeError(e);
        }
      }
    }
    return true;
  }
}
