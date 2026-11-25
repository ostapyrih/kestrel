import 'dart:async';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';

/// In-memory [RnsInterface] pair for tests without sockets or Python.
class MemoryInterface implements RnsInterface {
  MemoryInterface(this.name, {this.hwMtu = 500, this.autoconfigureMtu = false});

  /// Two connected interfaces. [mtu] > 500 enables MTU discovery.
  static (MemoryInterface, MemoryInterface) pair({int mtu = 500}) {
    final a = MemoryInterface('mem-a', hwMtu: mtu, autoconfigureMtu: mtu > 500);
    final b = MemoryInterface('mem-b', hwMtu: mtu, autoconfigureMtu: mtu > 500);
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  @override
  final String name;
  @override
  final int hwMtu;
  @override
  final bool autoconfigureMtu;
  @override
  int get bitrate => 10 * 1000 * 1000;

  MemoryInterface? _peer;
  final _rx = StreamController<Uint8List>.broadcast();
  final _st = StreamController<InterfaceState>.broadcast();
  InterfaceState _state = InterfaceState.offline;

  /// Frames sent by this interface (for assertions).
  final List<Uint8List> sent = [];

  /// If set, return false to drop a frame instead of delivering it.
  bool Function(Uint8List raw)? dropFilter;

  @override
  InterfaceState get state => _state;
  @override
  bool get online => _state == InterfaceState.online;
  @override
  Stream<InterfaceState> get stateChanges => _st.stream;
  @override
  Stream<Uint8List> get received => _rx.stream;

  @override
  Future<void> start() async {
    _state = InterfaceState.online;
    _st.add(_state);
  }

  @override
  Future<void> stop() async {
    _state = InterfaceState.offline;
    await _st.close();
    await _rx.close();
  }

  @override
  Future<bool> send(Uint8List raw) async {
    if (!online) return false;
    sent.add(raw);
    if (dropFilter != null && dropFilter!(raw)) return true;
    final p = _peer;
    if (p != null && !p._rx.isClosed) {
      final copy = Uint8List.fromList(raw);
      scheduleMicrotask(() {
        if (!p._rx.isClosed) p._rx.add(copy);
      });
    }
    return true;
  }
}
