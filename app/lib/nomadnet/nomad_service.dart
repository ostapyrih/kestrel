import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:kestrel_rns/kestrel_rns.dart';

import '../node/node_service.dart';
import 'browser_controller.dart';
import 'nomad_store.dart';
import 'page_cache.dart';

/// [FileSaver] over the platform save dialog / share sheet (file_picker).
class PlatformFileSaver implements FileSaver {
  const PlatformFileSaver();

  @override
  Future<String?> save(String fileName, Uint8List bytes) async {
    final uri = await FilePicker.saveFile(fileName: fileName, bytes: bytes);
    if (uri == null) return null;
    return uri.scheme == 'file' ? uri.toFilePath() : fileName;
  }
}

/// The NomadNet browser of the app: discovers nodes from announces (aspect
/// `nomadnetwork.node`), stores them, and owns the single
/// [BrowserController]. Works on identity B's Reticulum transport and does
/// not depend on the bridge.
class NomadService {
  NomadService({
    required this.node,
    required this.store,
    FileSaver? saver,
    PageCache? pageCache,
    NomadFetchFn? fetchOverride,
  }) : cache = pageCache ?? PageCache(store) {
    browser = BrowserController(
      fetch: fetchOverride ?? _fetch,
      store: store,
      cache: cache,
      saver: saver ?? const PlatformFileSaver(),
      waitReady: fetchOverride != null ? null : () => _ready.future,
    );
  }

  final NodeService node;
  final NomadStore store;
  final PageCache cache;
  late final BrowserController browser;

  NomadClient? _client;
  StreamSubscription<AnnounceEvent>? _sub;
  final _ready = Completer<void>();

  NomadClient? get client => _client;

  /// Starts listening for node announces once the Reticulum node is up.
  Future<void> start() async {
    try {
      await node.ready;
      _client = NomadClient(node.rns);
      _sub = node.rns.announces.listen(_onAnnounce);
      await cache.purgeExpired();
      if (!_ready.isCompleted) _ready.complete();
    } on Object catch (e, st) {
      if (!_ready.isCompleted) _ready.completeError(e, st);
    }
  }

  void _onAnnounce(AnnounceEvent e) {
    final n = NomadNodeAnnounce.fromEvent(e);
    if (n == null) return;
    unawaited(store.upsertAnnounced(n.hashHex, name: n.name, hops: n.hops));
  }

  NomadFetch _fetch(
    Uint8List hash,
    String path, {
    Map<String, String>? data,
    bool identify = false,
  }) => _client!.fetch(
    hash,
    path,
    data: data,
    identify: identify,
    identity: node.identity,
  );

  Future<void> stop() async {
    await _sub?.cancel();
    browser.dispose();
    await _client?.close();
  }
}
