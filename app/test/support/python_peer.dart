import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Locates a Python interpreter with rns+lxmf: `$KESTREL_PYTHON`, else
/// `tools/.venv` of the repository.
String? findPython() {
  final env = Platform.environment['KESTREL_PYTHON'];
  if (env != null && env.isNotEmpty) return env;
  for (final p in const [
    '../tools/.venv/Scripts/python.exe',
    '../tools/.venv/bin/python',
  ]) {
    if (File(p).existsSync()) return File(p).absolute.path;
  }
  return null;
}

/// Drives `tools/it/lxmf_peer.py` (RNS + LXMRouter reference peer).
class LxmfPeer {
  LxmfPeer._(this._proc, this.ready);

  final Process _proc;
  final Map<String, Object?> ready;
  final List<Map<String, Object?>> _queue = [];
  final List<_Waiter> _waiters = [];

  int get port => ready['port']! as int;
  String get destHash => ready['dest_hash']! as String;

  static Future<LxmfPeer> start({String name = 'Python Peer'}) async {
    final python = findPython();
    if (python == null) throw StateError('no python with rns found');
    final proc = await Process.start(python, [
      '../tools/it/lxmf_peer.py',
      '--name',
      name,
    ]);
    final readyC = Completer<Map<String, Object?>>();
    late LxmfPeer peer;
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
      line,
    ) {
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
    peer = LxmfPeer._(proc, ready);
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

  void send(Map<String, Object?> cmd) => _proc.stdin.writeln(json.encode(cmd));

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
    return w.completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(w);
        throw TimeoutException('peer event $event not seen', timeout);
      },
    );
  }

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
