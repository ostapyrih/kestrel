import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'destination.dart';
import 'identity.dart';
import 'interfaces/interface.dart';
import 'link/link.dart';
import 'storage.dart';
import 'transport/receipt.dart';
import 'transport/transport.dart';
import 'util.dart';

/// Configuration for [Reticulum.start].
class ReticulumConfig {
  ReticulumConfig({
    required this.interfaces,
    KestrelStorage? storage,
    this.transport = const TransportConfig(),
  }) : storage = storage ?? MemoryStorage();

  /// Interfaces to attach, e.g. a `TcpClientInterface`. Later an
  /// `RNodeBleInterface` plugs in here.
  final List<RnsInterface> interfaces;

  /// Persistence for known destinations, stamps and ratchets.
  final KestrelStorage storage;

  final TransportConfig transport;
}

/// An interface state change.
class InterfaceEvent {
  InterfaceEvent(this.interface, this.state);
  final RnsInterface interface;
  final InterfaceState state;
}

/// A Reticulum node (client/endpoint): interfaces + [Transport] + storage
/// behind an async API. There are no global singletons: create as many
/// instances as needed (tests run several in one process).
class Reticulum {
  Reticulum._(this.config, this.transport);

  final ReticulumConfig config;
  final Transport transport;
  final _ifaceEvents = StreamController<InterfaceEvent>.broadcast();
  final List<StreamSubscription<InterfaceState>> _ifaceSubs = [];

  /// Creates the transport, attaches all [ReticulumConfig.interfaces] and
  /// starts connecting.
  static Future<Reticulum> start(ReticulumConfig config) async {
    final t = Transport(storage: config.storage, config: config.transport);
    final r = Reticulum._(config, t);
    await t.start();
    for (final i in config.interfaces) {
      await r.addInterface(i);
    }
    return r;
  }

  KestrelStorage get storage => config.storage;

  /// All accepted announces.
  Stream<AnnounceEvent> get announces => transport.announces;

  /// Connection state changes of every attached interface.
  Stream<InterfaceEvent> get interfaceEvents => _ifaceEvents.stream;

  List<RnsInterface> get interfaces => List.unmodifiable(transport.interfaces);

  Future<void> addInterface(RnsInterface i) async {
    _ifaceSubs.add(
      i.stateChanges.listen((s) {
        if (!_ifaceEvents.isClosed) _ifaceEvents.add(InterfaceEvent(i, s));
      }),
    );
    await transport.addInterface(i);
  }

  /// Creates and registers an inbound SINGLE destination for [identity]
  /// (e.g. `lxmf.delivery`). Persisted ratchets are used if [ratchets] is
  /// true.
  Future<Destination> createDestination(
    Identity identity,
    String appName,
    List<String> aspects, {
    bool ratchets = false,
  }) async {
    final d = Destination.single(
      identity,
      appName,
      aspects,
      direction: DestinationDirection.inbound,
    );
    if (ratchets) await enableRatchets(d);
    transport.registerDestination(d);
    return d;
  }

  /// Creates an inbound PLAIN destination.
  Destination createPlainDestination(String appName, List<String> aspects) {
    final d = Destination.plain(appName, aspects);
    transport.registerDestination(d);
    return d;
  }

  /// Builds an outbound destination for a recalled identity, or null if the
  /// hash is unknown or does not match `appName.aspects`.
  Destination? recallDestination(
    List<int> destinationHash,
    String appName,
    List<String> aspects,
  ) =>
      transport.outboundDestination(destinationHash, appName, aspects);

  /// Remembers a destination of an identity known only by its public key
  /// (see [Transport.rememberDestination]); returns the destination hash.
  Uint8List rememberDestination(
    List<int> publicKey,
    String appName,
    List<String> aspects,
  ) =>
      transport.rememberDestination(publicKey, appName, aspects);

  /// Loads/creates persisted ratchets for [d] (Destination.enable_ratchets).
  Future<void> enableRatchets(Destination d) async {
    final key = 'ratchets/${toHex(d.hash)}';
    final stored = await storage.read(key);
    final list = <Uint8List>[
      for (final e in (stored?['ratchets'] as List<Object?>? ?? const []))
        base64.decode(e! as String),
    ];
    final times = <int>[
      for (final e in (stored?['times'] as List<Object?>? ?? const []))
        (e as num).toInt(),
    ];
    d.enableRatchets(list, times);
    d.onRatchetsChanged = (r) => storage.write(key, {
          'ratchets': [for (final x in r) base64.encode(x)],
          'times': d.ratchetCreationTimes,
        });
  }

  /// Announces [destination] (with PoW stamp when enabled in
  /// [TransportConfig]; generation runs on a background isolate).
  Future<bool> announce(Destination destination, {List<int>? appData}) =>
      transport.announce(destination, appData: appData);

  Future<void> requestPath(List<int> destinationHash) =>
      transport.requestPath(destinationHash);

  Future<bool> awaitPath(
    List<int> destinationHash, {
    Duration timeout = const Duration(seconds: 15),
  }) =>
      transport.awaitPath(destinationHash, timeout: timeout);

  /// Sends an encrypted packet to [destination]; the receipt completes when
  /// the peer's proof arrives.
  Future<PacketReceipt?> send(Destination destination, List<int> data) =>
      transport.sendData(destination, data);

  /// Establishes a link to [destination], requesting a path first if needed.
  /// Throws [StateError] on timeout or failure.
  Future<Link> connect(
    Destination destination, {
    Duration pathTimeout = const Duration(seconds: 15),
  }) async {
    if (!transport.hasPath(destination.hash)) {
      await transport.awaitPath(destination.hash, timeout: pathTimeout);
    }
    final link = await Link.initiate(transport, destination);
    await link.established;
    return link;
  }

  /// Stream of established inbound links for [destination].
  Stream<Link> incomingLinks(Destination destination) {
    final c = StreamController<Link>.broadcast();
    destination.onLinkEstablished = (l) => c.add(l as Link);
    return c.stream;
  }

  Future<void> stop() async {
    for (final s in _ifaceSubs) {
      await s.cancel();
    }
    await transport.stop();
    await _ifaceEvents.close();
  }
}
