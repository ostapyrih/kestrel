import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../framing/hdlc.dart';
import 'interface.dart';

/// Opens a socket; injectable for tests.
typedef SocketConnector = Future<Socket> Function(
  String host,
  int port,
  Duration timeout,
);

/// Reticulum `TCPClientInterface` (RNS/Interfaces/TCPInterface.py): HDLC
/// framed packets over a TCP connection, with automatic reconnect.
///
/// Parameters mirror the reference: `HW_MTU = 262144`, `BITRATE_GUESS =
/// 10 Mbit/s`, `AUTOCONFIGURE_MTU`, connect timeout 5 s, reconnect wait 5 s
/// (here with optional exponential backoff up to [maxReconnectDelay]).
/// Does not implement IFAC or KISS framing (`kiss_framing`).
class TcpClientInterface implements RnsInterface {
  TcpClientInterface({
    required this.host,
    required this.port,
    this.connectTimeout = const Duration(seconds: 5),
    this.reconnectDelay = const Duration(seconds: 5),
    Duration? maxReconnectDelay,
    this.maxReconnectTries,
    this.hwMtu = Hdlc.defaultHwMtu,
    SocketConnector? connector,
  })  : maxReconnectDelay = maxReconnectDelay ?? reconnectDelay,
        _connector = connector ?? _defaultConnector;

  final String host;
  final int port;
  final Duration connectTimeout;
  final Duration reconnectDelay;
  final Duration maxReconnectDelay;
  final int? maxReconnectTries;
  final SocketConnector _connector;

  @override
  final int hwMtu;
  @override
  bool get autoconfigureMtu => true;
  @override
  int get bitrate => 10 * 1000 * 1000;
  @override
  String get name => 'TCPInterface[$host:$port]';

  final _state = StreamController<InterfaceState>.broadcast();
  final _rx = StreamController<Uint8List>.broadcast();
  InterfaceState _current = InterfaceState.offline;
  Socket? _socket;
  HdlcDecoder _decoder = HdlcDecoder();
  bool _stopped = false;
  Timer? _retryTimer;
  int _attempts = 0;

  @override
  InterfaceState get state => _current;
  @override
  bool get online => _current == InterfaceState.online;
  @override
  Stream<InterfaceState> get stateChanges => _state.stream;
  @override
  Stream<Uint8List> get received => _rx.stream;

  static Future<Socket> _defaultConnector(
    String host,
    int port,
    Duration timeout,
  ) =>
      Socket.connect(host, port, timeout: timeout);

  void _set(InterfaceState s) {
    if (_current == s) return;
    _current = s;
    if (!_state.isClosed) _state.add(s);
  }

  @override
  Future<void> start() async {
    _stopped = false;
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (_stopped) return;
    _set(InterfaceState.connecting);
    try {
      final s = await _connector(host, port, connectTimeout);
      if (_stopped) {
        s.destroy();
        return;
      }
      s.setOption(SocketOption.tcpNoDelay, true);
      _socket = s;
      _decoder = HdlcDecoder(hwMtu: hwMtu);
      _attempts = 0;
      _set(InterfaceState.online);
      s.listen(
        (chunk) {
          for (final f in _decoder.feed(chunk)) {
            if (!_rx.isClosed) _rx.add(f);
          }
        },
        onError: (Object _) => _lost(s),
        onDone: () => _lost(s),
        cancelOnError: true,
      );
    } on Object {
      _set(InterfaceState.offline);
      _scheduleRetry();
    }
  }

  void _lost(Socket s) {
    if (!identical(_socket, s)) return;
    _socket = null;
    s.destroy();
    _set(InterfaceState.offline);
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_stopped) return;
    _attempts++;
    final max = maxReconnectTries;
    if (max != null && _attempts > max) return;
    final factor = pow(2, min(_attempts - 1, 10)).toInt();
    var d = reconnectDelay * factor;
    if (d > maxReconnectDelay) d = maxReconnectDelay;
    _retryTimer?.cancel();
    _retryTimer = Timer(d, _connect);
  }

  @override
  Future<bool> send(Uint8List raw) async {
    final s = _socket;
    if (s == null || !online) return false;
    try {
      s.add(Hdlc.frame(raw));
      return true;
    } on Object {
      _lost(s);
      return false;
    }
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _retryTimer?.cancel();
    final s = _socket;
    _socket = null;
    s?.destroy();
    _set(InterfaceState.offline);
    await _state.close();
    await _rx.close();
  }
}
