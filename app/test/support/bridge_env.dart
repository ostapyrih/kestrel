import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'python_peer.dart' show findPython;

/// Drives `tools/it/bridge_env.py`: a Reticulum transport node, the fake
/// MeshChatX and the real kestrel-bridge sidecar on loopback.
class BridgeEnv {
  BridgeEnv._(this._proc, this.ready);

  final Process _proc;
  final Map<String, Object?> ready;
  final List<
    (bool Function(Map<String, Object?>), Completer<Map<String, Object?>>)
  >
  _waiters = [];

  int get tcpPort => ready['tcp_port']! as int;
  String get bridgePub => ready['bridge_pub']! as String;
  String get bridgeLxmf => ready['bridge_lxmf']! as String;
  String get peer => ready['peer']! as String;

  /// True if a Python with the bridge's dependencies is available.
  static bool get available {
    final py = findPython();
    if (py == null) return false;
    return Directory('../bridge/kestrel_bridge').existsSync() &&
        Process.runSync(py, [
              '-c',
              'import kestrel_bridge, aiohttp, msgpack',
            ]).exitCode ==
            0;
  }

  static Future<BridgeEnv> start(String bootstrapPublicKeyHex) async {
    final python = findPython()!;
    final proc = await Process.start(python, [
      '../tools/it/bridge_env.py',
      bootstrapPublicKeyHex,
    ]);
    final readyC = Completer<Map<String, Object?>>();
    late BridgeEnv env;
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
      l,
    ) {
      if (l.trim().isEmpty) return;
      Map<String, Object?> m;
      try {
        m = json.decode(l) as Map<String, Object?>;
      } on Object {
        return;
      }
      if (!readyC.isCompleted) {
        if (m['event'] == 'ready') {
          readyC.complete(m);
        } else {
          readyC.completeError(StateError('bridge env failed: $m'));
        }
        return;
      }
      env._dispatch(m);
    });
    unawaited(proc.stderr.drain<void>());
    final ready = await readyC.future.timeout(const Duration(seconds: 150));
    env = BridgeEnv._(proc, ready);
    return env;
  }

  void _dispatch(Map<String, Object?> m) {
    for (final w in _waiters) {
      if (w.$1(m)) {
        _waiters.remove(w);
        w.$2.complete(m);
        return;
      }
    }
  }

  Future<Map<String, Object?>> ask(Map<String, Object?> cmd, String event) {
    final c = Completer<Map<String, Object?>>();
    _waiters.add((((m) => m['event'] == event), c));
    _proc.stdin.writeln(json.encode(cmd));
    return c.future.timeout(const Duration(seconds: 30));
  }

  Future<Map<String, Object?>> calls() async =>
      (await ask({'cmd': 'calls'}, 'calls'))['calls']! as Map<String, Object?>;

  Future<void> emitMessage(String text, {String? hash}) =>
      ask({'cmd': 'emit_message', 'text': text, 'hash': ?hash}, 'emitted');

  Future<void> stop() async {
    try {
      _proc.stdin.writeln(json.encode({'cmd': 'quit'}));
    } on Object {
      // already gone
    }
    await _proc.exitCode.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _proc.kill();
        return -1;
      },
    );
  }
}
