import 'dart:async';

import '../storage.dart';
import 'device_sync.dart';

/// One batch of history served to a newly paired device.
class BackfillBatch {
  BackfillBatch({
    required this.phase,
    required this.items,
    this.nextPhase,
    this.nextCursor = 0,
    this.total,
  });

  /// The phase these [items] belong to (the sink interprets them).
  final String phase;
  final List<Object?> items;

  /// Where the next request continues; a null [nextPhase] ends the stream.
  final String? nextPhase;
  final int nextCursor;

  /// Total number of items of the whole stream, when known (progress).
  final int? total;
}

/// The history of the group on an existing device (the serving side).
abstract class BackfillSource {
  /// Reads the batch at ([phase], [cursor]); a null [phase] starts the stream.
  /// Cursors are positions in the source's own order (e.g. a message id), so a
  /// repeated request returns the same batch.
  Future<BackfillBatch> read(String? phase, int cursor);
}

/// Applies a received batch on the new device. Must be idempotent (dedupe by
/// message hash): a batch may arrive twice.
abstract class BackfillSink {
  Future<void> apply(String phase, List<Object?> items);
}

/// What the new device shows ("Syncing history...").
class BackfillProgress {
  const BackfillProgress({
    this.active = false,
    this.done = false,
    this.applied = 0,
    this.total = 0,
  });
  final bool active;
  final bool done;
  final int applied;
  final int total;

  double? get fraction =>
      total > 0 ? (applied / total).clamp(0.0, 1.0).toDouble() : null;
}

/// History backfill over the device sync channel (docs/device-sync.md).
///
/// Pull model, resumable: the new device asks a sibling for the batch at
/// `(phase, cursor)` with a targeted `backfill_req` record; the sibling answers
/// with a targeted `backfill` record that carries the items and where the next
/// request continues. The new device persists the position after each applied
/// batch (restarts resume), re-asks when no answer arrives (rotating through the
/// other siblings) and ignores answers for positions it already passed. The
/// records are encrypted like all sync records; the router sends them directly
/// when the sibling is online and via the propagation node otherwise.
class DeviceBackfill {
  DeviceBackfill({
    required this.sync,
    required this.storage,
    this.source,
    this.sink,
    this.retry = const Duration(seconds: 20),
  });

  final DeviceSync sync;
  final KestrelStorage storage;

  /// Serves requests of siblings (null: this device never serves).
  final BackfillSource? source;

  /// Applies received history (null: this device never requests).
  final BackfillSink? sink;
  final Duration retry;

  static const _key = 'sync/backfill';

  final _progress = StreamController<BackfillProgress>.broadcast();
  StreamSubscription<SyncRecord>? _sub;
  Timer? _timer;
  Future<void> _tail = Future.value();
  bool _stopped = false;

  // client state
  bool _active = false;
  bool _done = false;
  String? _from;
  String? _phase;
  int _cursor = 0;
  int _applied = 0;
  int _total = 0;
  int _tries = 0;

  BackfillProgress get progress => BackfillProgress(
        active: _active,
        done: _done,
        applied: _applied,
        total: _total,
      );
  Stream<BackfillProgress> get progressChanges => _progress.stream;

  /// Loads the persisted position, listens for records and resumes an
  /// unfinished backfill.
  Future<void> init() async {
    final m = await storage.read(_key);
    if (m != null) {
      _active = m['active'] == true;
      _done = m['done'] == true;
      _from = m['from'] as String?;
      _phase = m['p'] as String?;
      _cursor = (m['c'] as int?) ?? 0;
      _applied = (m['applied'] as int?) ?? 0;
      _total = (m['total'] as int?) ?? 0;
    }
    _sub = sync.records.listen((r) {
      if (r.kind == SyncKind.backfillRequest) {
        _enqueue(() => _serve(r));
      } else if (r.kind == SyncKind.backfill) {
        _enqueue(() => _receive(r));
      }
    });
    if (_active && !_done) _enqueue(_request);
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    await _sub?.cancel();
    await _progress.close();
  }

  void _enqueue(Future<void> Function() f) {
    _tail = _tail.then((_) => f()).catchError((Object _) {});
  }

  /// Waits for queued handling (tests).
  Future<void> flush() => _tail;

  Future<void> _save() => storage.write(_key, {
        'active': _active,
        'done': _done,
        'from': _from,
        'p': _phase,
        'c': _cursor,
        'applied': _applied,
        'total': _total,
      });

  void _emit() {
    if (!_progress.isClosed) _progress.add(progress);
  }

  // ------------------------------------------------------------ new device

  /// Starts requesting the history from [from] (device id, normally the
  /// pairing host). A finished backfill is not repeated.
  Future<void> start({String? from}) async {
    if (sink == null || _done) return;
    _active = true;
    _from = from ?? _from ?? _nextSibling(null);
    _tries = 0;
    await _save();
    _emit();
    _enqueue(_request);
  }

  String? _nextSibling(String? after) {
    final ids = [
      for (final d in sync.state.devices.active)
        if (d.id != sync.ownId) d.id
    ]..sort();
    if (ids.isEmpty) return null;
    if (after == null) return ids.first;
    final i = ids.indexOf(after);
    return ids[(i + 1) % ids.length];
  }

  Future<void> _request() async {
    if (_stopped || !_active || _done) return;
    var from = _from;
    if (from == null || !sync.state.devices.isActive(from)) {
      from = _from = _nextSibling(null);
    }
    if (from == null) return;
    await sync.publishTargeted(
      SyncKind.backfillRequest,
      {'p': _phase, 'c': _cursor},
      [from],
    );
    _timer?.cancel();
    _timer = Timer(retry, () {
      if (_stopped || !_active || _done) return;
      _tries++;
      if (_tries % 2 == 0) _from = _nextSibling(_from);
      _enqueue(_request);
    });
  }

  Future<void> _receive(SyncRecord r) async {
    final s = sink;
    final d = r.data;
    if (s == null || !_active || _done || d is! Map) return;
    // an answer for a position we already passed (or never asked for)
    if (d['rp'] != _phase || d['rc'] != _cursor) return;
    final sp = d['sp'];
    final items = d['items'];
    if (sp is! String || items is! List) return;
    await s.apply(sp, items.cast<Object?>());
    _applied += items.length;
    if (d['total'] is int) _total = d['total']! as int;
    final np = d['np'];
    _timer?.cancel();
    _tries = 0;
    _from = r.origin;
    if (np is String) {
      _phase = np;
      _cursor = (d['nc'] as int?) ?? 0;
      await _save();
      _emit();
      await _request();
    } else {
      _done = true;
      _active = false;
      await _save();
      _emit();
    }
  }

  // ------------------------------------------------------------ serving

  Future<void> _serve(SyncRecord r) async {
    final src = source;
    final d = r.data;
    if (src == null || d is! Map) return;
    final p = d['p'];
    final c = d['c'];
    if ((p != null && p is! String) || c is! int) return;
    final b = await src.read(p as String?, c);
    await sync.publishTargeted(
      SyncKind.backfill,
      {
        'rp': p,
        'rc': c,
        'sp': b.phase,
        'items': b.items,
        'np': b.nextPhase,
        'nc': b.nextCursor,
        if (b.total != null) 'total': b.total,
      },
      [r.origin],
    );
  }
}
