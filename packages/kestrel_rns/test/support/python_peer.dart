import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Locates a Python interpreter with rns+lxmf: `$KESTREL_PYTHON`, else
/// `tools/.venv`.
String? findPython() {
  final env = Platform.environment['KESTREL_PYTHON'];
  if (env != null && env.isNotEmpty) return env;
  for (final p in const [
    '../../tools/.venv/Scripts/python.exe',
    '../../tools/.venv/bin/python',
  ]) {
    if (File(p).existsSync()) return File(p).absolute.path;
  }
  return null;
}

/// Drives `tools/it/rns_peer.py` (reference RNS peer) over its JSON-lines
/// protocol.
class PythonPeer {
  PythonPeer._(this._proc, this.ready);

  final Process _proc;

  /// The peer's `ready` event (port, dest_hash, identity_hash, ...).
  final Map<String, Object?> ready;

  final List<Map<String, Object?>> _queue = [];
  final List<_Waiter> _waiters = [];

  int get port => ready['port']! as int;
  String get destHash => ready['dest_hash']! as String;

  static Future<PythonPeer> start({
    bool transport = false,
    int port = 0,
    bool stamps = false,
    double? destCost,
  }) async {
    final python = findPython();
    if (python == null) throw StateError('no python with rns found');
    final proc = await Process.start(python, [
      '../../tools/it/rns_peer.py',
      '--transport',
      transport ? 'yes' : 'no',
      '--port',
      '$port',
      if (stamps) '--stamps',
      if (destCost != null) ...['--dest-cost', '$destCost'],
    ]);
    final readyC = Completer<Map<String, Object?>>();
    late PythonPeer peer;
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) return;
      Map<String, Object?> m;
      try {
        m = json.decode(line) as Map<String, Object?>;
      } on Object {
        return;
      }
      if (!readyC.isCompleted) {
        readyC.complete(m);
        return;
      }
      peer._dispatch(m);
    });
    unawaited(proc.stderr.drain<void>());
    final ready = await readyC.future.timeout(const Duration(seconds: 40));
    peer = PythonPeer._(proc, ready);
    return peer;
  }

  void _dispatch(Map<String, Object?> m) {
    for (final w in _waiters) {
      if (w.matches(m)) {
        _waiters.remove(w);
        w.completer.complete(m);
        return;
      }
    }
    _queue.add(m);
  }

  void send(Map<String, Object?> cmd) {
    _proc.stdin.writeln(json.encode(cmd));
  }

  /// Waits for (and consumes) the next [event] matching [where].
  Future<Map<String, Object?>> waitFor(
    String event, {
    bool Function(Map<String, Object?>)? where,
    Duration timeout = const Duration(seconds: 30),
  }) {
    bool pred(Map<String, Object?> m) =>
        m['event'] == event && (where == null || where(m));
    final i = _queue.indexWhere(pred);
    if (i >= 0) return Future.value(_queue.removeAt(i));
    final w = _Waiter(pred);
    _waiters.add(w);
    return w.completer.future.timeout(timeout, onTimeout: () {
      _waiters.remove(w);
      throw TimeoutException('peer event $event not seen', timeout);
    });
  }

  /// True if an unconsumed [event] is queued.
  bool has(String event) => _queue.any((m) => m['event'] == event);

  Future<void> stop() async {
    _proc.kill();
    await _proc.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
  }
}

class _Waiter {
  _Waiter(this.matches);
  final bool Function(Map<String, Object?>) matches;
  final Completer<Map<String, Object?>> completer = Completer();
}
