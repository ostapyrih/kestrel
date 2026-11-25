import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';

/// Starts a Dart node connected to a python peer on loopback.
Future<Reticulum> node(
  int port, {
  TransportConfig? config,
  Duration reconnect = const Duration(milliseconds: 300),
}) async {
  final iface = TcpClientInterface(
    host: '127.0.0.1',
    port: port,
    reconnectDelay: reconnect,
    connectTimeout: const Duration(seconds: 2),
  );
  final r = await Reticulum.start(ReticulumConfig(
    interfaces: [iface],
    transport: config ??
        const TransportConfig(stampAnnounces: false, stampPathRequests: false),
  ));
  await waitOnline(iface);
  return r;
}

Future<void> waitOnline(RnsInterface i) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!i.online) {
    if (DateTime.now().isAfter(end)) throw StateError('not connected');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Mirror of `pseudo_random` in tools/it/rns_peer.py.
Uint8List pseudoRandom(int n, {String seed = 'kestrel-it'}) {
  final out = BytesBuilder();
  var c = 0;
  final s = seed.codeUnits;
  while (out.length < n) {
    out.add(sha256([
      ...s,
      (c >> 24) & 0xFF,
      (c >> 16) & 0xFF,
      (c >> 8) & 0xFF,
      c & 0xFF,
    ]));
    c++;
  }
  return Uint8List.sublistView(out.toBytes(), 0, n);
}

/// Waits until [cond] holds.
Future<void> until(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw StateError('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
