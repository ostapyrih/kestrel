import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:kestrel_rns/kestrel_rns.dart';

import 'micron/micron_parser.dart';
import 'nomad_store.dart';
import 'page_cache.dart';

/// Saves a downloaded file through the platform (save dialog / share sheet).
/// Returns a description of where it went, or null if the user cancelled.
abstract class FileSaver {
  Future<String?> save(String fileName, Uint8List bytes);
}

/// A file received from a node, not yet (or already) saved.
class NomadDownload {
  NomadDownload(this.name, this.bytes, {this.savedTo});
  final String name;
  final Uint8List bytes;
  String? savedTo;
  int get size => bytes.length;
}

/// Starts a request. `NomadClient.fetch` in production, a fake in tests.
typedef NomadFetchFn = NomadFetch Function(
  Uint8List hash,
  String path, {
  Map<String, String>? data,
  bool identify,
});

/// What the browser is doing right now.
enum BrowserPhase { idle, loading, loaded, failed }

/// Browser state machine over a [NomadClient]-like fetcher: current page,
/// back/forward history, page cache, bookmarks and file downloads. A
/// [ChangeNotifier] for the UI; contains no widgets.
class BrowserController extends ChangeNotifier {
  BrowserController({
    required this.fetch,
    required this.store,
    required this.cache,
    required this.saver,
    this.waitReady,
    this.dark = true,
  });

  final NomadFetchFn fetch;
  final NomadStore store;
  final PageCache cache;
  final FileSaver saver;

  /// Completes when the network node is up (requests wait for it).
  final Future<void> Function()? waitReady;

  /// Heading colour set used when parsing pages.
  bool dark;

  /// Called for `lxmf@<hash>` links: the app opens a chat with that address.
  void Function(String lxmfHashHex)? onOpenChat;

  // ------------------------------------------------------------------ state
  NomadUrl? current;
  MicronDocument? document;
  String? markup;
  String title = '';
  bool fromCache = false;
  BrowserPhase phase = BrowserPhase.idle;

  /// URL being loaded / that failed.
  NomadUrl? target;
  NomadProgress? progress;
  NomadFailure? failure;
  String? failureText;
  Duration? lastElapsed;
  int? lastTransferSize;
  int? lastHops;

  /// A downloaded file waiting to be saved / just saved.
  NomadDownload? download;

  /// Anchor to scroll to after the next page is shown (`var_anchor`).
  String? pendingAnchor;

  final List<NomadUrl> _back = [];
  final List<NomadUrl> _forward = [];
  NomadFetch? _active;
  int _seq = 0;

  bool get canGoBack => _back.isNotEmpty;
  bool get canGoForward => _forward.isNotEmpty;
  bool get loading => phase == BrowserPhase.loading;
  List<NomadUrl> get backStack => List.unmodifiable(_back);

  // ------------------------------------------------------------- navigation

  /// Opens an address typed by the user (`<hash>`, `<hash>:/page/x.mu`).
  /// Returns false (and sets an error) if it is malformed.
  Future<bool> open(String input) async {
    final u = NomadUrl.tryParse(input, current: current?.hash);
    if (u == null) {
      _setFailure(null, 'malformed');
      return false;
    }
    await go(u);
    return true;
  }

  /// Navigates to [url] as a new history entry.
  Future<void> go(NomadUrl url, {Map<String, String>? data}) =>
      _load(url, data: data, history: _HistoryOp.push);

  Future<void> back() async {
    if (_back.isEmpty) return;
    final u = _back.removeLast();
    if (current != null) _forward.add(current!);
    await _load(u, history: _HistoryOp.none);
  }

  Future<void> forward() async {
    if (_forward.isEmpty) return;
    final u = _forward.removeLast();
    if (current != null) _back.add(current!);
    await _load(u, history: _HistoryOp.none);
  }

  /// Reloads the current page, bypassing (and dropping) the cache.
  Future<void> reload() async {
    final u = current ?? target;
    if (u == null) return;
    await cache.remove(u.text);
    await _load(u, history: _HistoryOp.none, useCache: false);
  }

  /// Aborts a running request.
  Future<void> cancel() async {
    final f = _active;
    if (f == null) return;
    _seq++;
    _active = null;
    await f.cancel();
    phase = document == null ? BrowserPhase.idle : BrowserPhase.loaded;
    progress = null;
    notifyListeners();
  }

  /// Activates a link from the page: [rawTarget] as written in the markup,
  /// [data] the request data built from the form (`var_*`/`field_*`).
  Future<void> followLink(String rawTarget, Map<String, String>? data) async {
    final link = NomadLink.parse(rawTarget);
    switch (link.kind) {
      case NomadLinkKind.node:
        final u = NomadUrl.tryParse(link.url!, current: current?.hash);
        if (u == null) {
          _setFailure(null, 'malformed');
          return;
        }
        await go(u, data: data);
      case NomadLinkKind.lxmf:
        onOpenChat?.call(link.lxmfHash!);
      case NomadLinkKind.anchor:
        pendingAnchor = link.anchor;
        notifyListeners();
      case NomadLinkKind.rrc || NomadLinkKind.partial || NomadLinkKind.unknown:
        _setFailure(null, 'unsupported:${link.raw}');
    }
  }

  void _setFailure(NomadFailure? f, String text) {
    failure = f;
    failureText = text;
    phase = BrowserPhase.failed;
    notifyListeners();
  }

  // ---------------------------------------------------------------- loading

  Future<void> _load(
    NomadUrl url, {
    Map<String, String>? data,
    required _HistoryOp history,
    bool useCache = true,
  }) async {
    final prev = _active;
    if (prev != null) unawaited(prev.cancel());
    final my = ++_seq;

    final merged = <String, String>{...?url.requestData, ...?data};
    final requestData = merged.isEmpty ? null : merged;

    target = url;
    failure = null;
    failureText = null;
    progress = null;
    pendingAnchor = null;

    // pages without request data may come from the cache (not files)
    if (requestData == null && useCache && !url.isFile) {
      final hit = await cache.get(url.text);
      if (my != _seq) return;
      if (hit != null) {
        _show(url, hit, history, fromCache: true);
        return;
      }
    }

    phase = BrowserPhase.loading;
    await store.ensureNode(url.hashHex);
    if (my != _seq) return;
    final node = await store.node(url.hashHex);
    if (my != _seq) return;
    notifyListeners();
    if (waitReady != null) {
      try {
        await waitReady!();
      } on Object {
        if (my != _seq) return;
        failure = NomadFailure.linkFailed;
        failureText = 'node not ready';
        phase = BrowserPhase.failed;
        notifyListeners();
        return;
      }
      if (my != _seq) return;
    }

    final f = fetch(
      url.hash,
      url.path,
      data: requestData,
      identify: node?.identify ?? false,
    );
    _active = f;
    final sub = f.progress.listen((p) {
      if (my != _seq) return;
      progress = p;
      notifyListeners();
    });
    try {
      final r = await f.result;
      if (my != _seq) return;
      lastElapsed = r.elapsed;
      lastTransferSize = r.transferSize;
      lastHops = r.hops;
      if (url.isFile || r.isFile) {
        download = NomadDownload(
          _safeFileName(r.fileName ?? url.path.split('/').last),
          r.data,
        );
        phase = document == null ? BrowserPhase.idle : BrowserPhase.loaded;
        progress = null;
        notifyListeners();
        return;
      }
      final text = r.text;
      final doc = parseMicron(text, dark: dark);
      if (requestData == null) {
        await cache.put(url.text, r.data, doc.cacheSeconds);
      }
      _show(url, r.data, history, fromCache: false, parsed: doc);
    } on NomadException catch (e) {
      if (my != _seq) return;
      failure = e.failure;
      failureText = e.message;
      phase = BrowserPhase.failed;
      progress = null;
      if (e.failure == NomadFailure.cancelled) {
        phase = document == null ? BrowserPhase.idle : BrowserPhase.loaded;
        failure = null;
      }
      notifyListeners();
    } finally {
      await sub.cancel();
      if (my == _seq) _active = null;
    }
  }

  void _show(
    NomadUrl url,
    Uint8List data,
    _HistoryOp history, {
    required bool fromCache,
    MicronDocument? parsed,
  }) {
    final text = utf8.decode(data, allowMalformed: true);
    final doc = parsed ?? parseMicron(text, dark: dark);
    if (history == _HistoryOp.push) {
      if (current != null && current != url) _back.add(current!);
      _forward.clear();
    }
    current = url;
    target = url;
    document = doc;
    markup = text;
    this.fromCache = fromCache;
    title = _titleOf(doc, url);
    phase = BrowserPhase.loaded;
    progress = null;
    pendingAnchor = url.vars['anchor'];
    _active = null;
    unawaited(store.addHistory(url.text, title));
    notifyListeners();
  }

  static String _titleOf(MicronDocument doc, NomadUrl url) {
    for (final b in doc.blocks) {
      if (b.kind == MicronBlockKind.heading) {
        final t = b.plainText.trim();
        if (t.isNotEmpty) return t;
      }
    }
    return url.hashHex.substring(0, 8);
  }

  // -------------------------------------------------------------- downloads

  /// Saves the pending download through [saver]. Returns true if saved.
  Future<bool> saveDownload() async {
    final d = download;
    if (d == null) return false;
    final where = await saver.save(d.name, d.bytes);
    if (where != null) {
      d.savedTo = where;
      notifyListeners();
      return true;
    }
    return false;
  }

  void dismissDownload() {
    download = null;
    notifyListeners();
  }

  // -------------------------------------------------------------- bookmarks

  Future<bool> isBookmarked() async {
    final u = current;
    return u != null && await store.isBookmarked(u.text);
  }

  Future<void> toggleBookmark() async {
    final u = current;
    if (u == null) return;
    if (await store.isBookmarked(u.text)) {
      await store.removeBookmark(u.text);
    } else {
      await store.addBookmark(u.text, title);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _seq++;
    unawaited(_active?.cancel());
    super.dispose();
  }
}

enum _HistoryOp { push, none }

/// A file name suggested by a remote node: base name only, no path separators
/// or control characters, never empty or a dot name.
String _safeFileName(String name) {
  final base = name.split(RegExp(r'[/\\]')).last;
  final clean = base.replaceAll(RegExp(r'[\x00-\x1f:*?"<>|]'), '_').trim();
  return (clean.isEmpty || clean == '.' || clean == '..') ? 'download' : clean;
}
