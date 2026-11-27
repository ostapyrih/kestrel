import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../identity.dart';
import '../link/link.dart';
import '../reticulum.dart';
import '../util.dart';
import 'nomad_node.dart';

/// What a fetch is currently doing (drives the loading indicator).
enum NomadPhase { findingPath, connecting, requesting, receiving }

/// Progress of a [NomadFetch].
class NomadProgress {
  const NomadProgress(
    this.phase, {
    this.progress = 0,
    this.hops,
    this.reusedLink = false,
    this.responseSize,
  });

  final NomadPhase phase;

  /// 0..1 while [NomadPhase.receiving].
  final double progress;

  /// Hops to the node, if a path is known.
  final int? hops;

  /// True if an already open link to the node is used.
  final bool reusedLink;

  /// Size of the (uncompressed) response, once the node announced it.
  final int? responseSize;
}

enum NomadFailure {
  noPath,
  linkFailed,
  timeout,
  requestFailed,
  tooLarge,
  cancelled,
  badResponse,
}

class NomadException implements Exception {
  NomadException(this.failure, [this.message = '']);
  final NomadFailure failure;
  final String message;

  @override
  String toString() => 'NomadException(${failure.name}) $message';
}

/// A successful response.
class NomadResult {
  NomadResult({
    required this.data,
    this.fileName,
    required this.elapsed,
    this.transferSize,
    this.hops,
  });

  /// Raw response bytes (page markup or file contents).
  final Uint8List data;

  /// Set for a file response (`[file, {name: ...}]`); null for pages.
  final String? fileName;
  final Duration elapsed;

  /// Bytes on the wire for the response (compressed), if known.
  final int? transferSize;
  final int? hops;

  bool get isFile => fileName != null;

  String get text => utf8.decode(data, allowMalformed: true);
}

/// One in-flight request. Listen to [progress], await [result], or
/// [cancel].
class NomadFetch {
  NomadFetch._(this._cancel);

  final Future<void> Function() _cancel;
  final _progress = StreamController<NomadProgress>.broadcast();
  final _result = Completer<NomadResult>();

  Stream<NomadProgress> get progress => _progress.stream;

  /// Completes with the response or a [NomadException].
  Future<NomadResult> get result => _result.future;

  bool get isDone => _result.isCompleted;

  /// Abandons the fetch; [result] fails with [NomadFailure.cancelled].
  Future<void> cancel() => _cancel();

  void _emit(NomadProgress p) {
    if (!_progress.isClosed && !_result.isCompleted) _progress.add(p);
  }

  void _finish(NomadResult r) {
    if (_result.isCompleted) return;
    _result.complete(r);
    _progress.close();
  }

  void _fail(NomadException e) {
    if (_result.isCompleted) return;
    _result.completeError(e);
    // never produce an "unhandled error" if nobody awaits result
    unawaited(_result.future.then<void>((_) {}, onError: (Object _) {}));
    _progress.close();
  }
}

class _Session {
  _Session(this.hash);
  final Uint8List hash;
  Link? link;
  Future<Link>? connecting;
  int active = 0;
  Timer? idle;
  bool identified = false;
}

/// NomadNet node protocol client over a [Reticulum] node: request a path,
/// open a link to the `nomadnetwork.node` destination, `request()` a page or
/// file and deliver the response (inline or as a Resource, including
/// multi-segment file resources). One link is kept per node while browsing
/// and torn down after [idleTimeout] without activity.
class NomadClient {
  NomadClient(
    this.rns, {
    this.pathTimeout = const Duration(seconds: 20),
    this.stallTimeout = const Duration(seconds: 90),
    this.idleTimeout = const Duration(minutes: 2),
    this.maxPageSize = 2 * 1024 * 1024,
    this.maxFileSize = 16 * 1024 * 1024,
  });

  final Reticulum rns;

  /// How long to wait for a path to a node before giving up.
  final Duration pathTimeout;

  /// A response transfer making no progress for this long is abandoned.
  final Duration stallTimeout;

  /// An unused link is closed after this long.
  final Duration idleTimeout;

  /// Responses larger than this are refused (pages) ...
  final int maxPageSize;

  /// ... or files (the transport's `maxResourceSize` also applies).
  final int maxFileSize;

  final Map<String, _Session> _sessions = {};
  bool _closed = false;

  /// True if a link to [hash] is currently open.
  bool hasLink(Uint8List hash) =>
      _sessions[toHex(hash)]?.link?.isActive ?? false;

  /// Requests [path] from the node [hash].
  ///
  /// [data] is the request data NomadNet sends (`field_*` / `var_*`, see
  /// `buildNomadRequestData`). With [identify] and an [identity] the link is
  /// identified before the first request (reveals the identity to the node).
  NomadFetch fetch(
    Uint8List hash,
    String path, {
    Map<String, String>? data,
    bool identify = false,
    Identity? identity,
  }) {
    final key = toHex(hash);
    final isFile = path.startsWith('/file/');
    final started = DateTime.now();
    RequestReceipt? receipt;
    Timer? stall;
    var cancelled = false;
    late final NomadFetch f;
    f = NomadFetch._(() async {
      cancelled = true;
      stall?.cancel();
      await receipt?.cancel();
      f._fail(NomadException(NomadFailure.cancelled));
    });
    final session = _sessions.putIfAbsent(key, () => _Session(hash));
    session.active++;
    session.idle?.cancel();

    Future<void> run() async {
      if (_closed) throw NomadException(NomadFailure.cancelled);
      int? hops() {
        final h = rns.transport.hopsTo(hash);
        return h >= 128 ? null : h;
      }

      var link = session.link;
      final reused = link != null && link.isActive;
      if (!reused) {
        link = null;
        f._emit(NomadProgress(NomadPhase.findingPath, hops: hops()));
        if (!rns.transport.hasPath(hash)) {
          final ok = await rns.awaitPath(hash, timeout: pathTimeout);
          if (cancelled) return;
          if (!ok) throw NomadException(NomadFailure.noPath);
        }
        f._emit(NomadProgress(NomadPhase.connecting, hops: hops()));
        final dest =
            rns.recallDestination(hash, nomadNodeApp, nomadNodeAspects);
        if (dest == null) throw NomadException(NomadFailure.noPath);
        final connecting = session.connecting ??= () async {
          try {
            final l = await Link.initiate(rns.transport, dest);
            await l.established;
            session.link = l;
            session.identified = false;
            unawaited(l.closed.then((_) {
              if (session.link == l) session.link = null;
            }));
            return l;
          } on Object {
            throw NomadException(NomadFailure.linkFailed);
          } finally {
            session.connecting = null;
          }
        }();
        link = await connecting;
        if (cancelled) return;
      }
      if (identify && identity != null && !session.identified) {
        session.identified = true;
        await link.identify(identity);
      }

      f._emit(NomadProgress(NomadPhase.requesting,
          hops: hops(), reusedLink: reused));
      final done = Completer<void>();
      void armStall() {
        stall?.cancel();
        stall = Timer(stallTimeout, () {
          if (!done.isCompleted) {
            unawaited(receipt?.cancel());
            f._fail(NomadException(NomadFailure.timeout, 'stalled'));
            done.complete();
          }
        });
      }

      final rr = await link.request(
        path,
        data: data,
        maxResponseSize: isFile ? maxFileSize : maxPageSize,
        onProgress: (r) {
          if (r.status == RequestStatus.receiving) {
            armStall();
            f._emit(NomadProgress(
              NomadPhase.receiving,
              progress: r.progress,
              hops: hops(),
              reusedLink: reused,
              responseSize: r.responseSize,
            ));
          }
        },
      );
      if (rr == null) throw NomadException(NomadFailure.requestFailed);
      receipt = rr;
      if (cancelled) {
        await rr.cancel();
        return;
      }
      armStall();
      await Future.any([rr.done, done.future]);
      stall?.cancel();
      if (f.isDone || cancelled) return;
      if (rr.status != RequestStatus.ready) {
        if (rr.tooLarge) throw NomadException(NomadFailure.tooLarge);
        final timedOut = DateTime.now().difference(started) >
            Duration(
                seconds: ((link.rtt ?? 1) * link.trafficTimeoutFactor).ceil());
        throw NomadException(
            timedOut ? NomadFailure.timeout : NomadFailure.requestFailed);
      }
      final resp = rr.response;
      final meta = rr.metadata;
      if (resp is! Uint8List) {
        // a node answering with None/False (e.g. denied) -> nothing to show
        throw NomadException(NomadFailure.badResponse);
      }
      String? name;
      if (meta is Map) {
        final n = meta['name'];
        if (n is Uint8List) name = utf8.decode(n, allowMalformed: true);
        if (n is String) name = n;
      }
      if (isFile && name == null) {
        name = path.split('/').last;
      }
      f._finish(NomadResult(
        data: resp,
        fileName: isFile ? name : null,
        elapsed: DateTime.now().difference(started),
        transferSize: rr.responseTransferSize,
        hops: hops(),
      ));
    }

    // start asynchronously so callers can listen to progress first
    Future<void>.microtask(run).catchError((Object e) {
      stall?.cancel();
      f._fail(e is NomadException
          ? e
          : NomadException(NomadFailure.requestFailed, '$e'));
    }).whenComplete(() {
      session.active--;
      _armIdle(session);
    });
    return f;
  }

  void _armIdle(_Session s) {
    if (s.active > 0 || s.link == null || _closed) return;
    s.idle?.cancel();
    s.idle = Timer(idleTimeout, () => _closeSession(s));
  }

  void _closeSession(_Session s) {
    final l = s.link;
    s.link = null;
    s.idle?.cancel();
    if (l != null) unawaited(l.teardown());
    _sessions.remove(toHex(s.hash));
  }

  /// Closes the link to [hash], if any.
  void disconnect(Uint8List hash) {
    final s = _sessions[toHex(hash)];
    if (s != null) _closeSession(s);
  }

  /// Closes every link.
  Future<void> close() async {
    _closed = true;
    for (final s in [..._sessions.values]) {
      _closeSession(s);
    }
  }
}
