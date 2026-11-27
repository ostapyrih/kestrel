/// Group-wide monotonic announce timebase (docs/spikes/device-group.md
/// sections 1 and 9).
///
/// Peers and transports order announces of one destination by the emission
/// time embedded in the announce's random blob (Transport.py:2631-2638): an
/// announce that was not emitted *later* than the one already in the path
/// table is rejected. With one identity on several devices, a device whose
/// wall clock runs behind would never be able to take over from a sibling
/// that announced last. The group therefore shares the last emitted time and
/// every announce uses `max(now, last + 1)`.
class AnnounceTimebase {
  AnnounceTimebase({int lastEmitted = 0, this.onChanged}) : _last = lastEmitted;

  int _last;

  /// Called whenever [lastEmitted] advanced (persist it / sync it).
  void Function(int lastEmitted)? onChanged;

  /// Largest emission time used (or observed) by the group so far.
  int get lastEmitted => _last;

  /// The emission time for the next announce: `max(now, last + 1)`.
  /// Consumes the value, so two announces never share a second.
  int next({int? nowSeconds}) {
    final now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final t = now > _last ? now : _last + 1;
    _last = t;
    onChanged?.call(t);
    return t;
  }

  /// Merges a value learned from a sibling (group sync): the timebase only
  /// moves forward. Returns whether it advanced.
  bool observe(int emittedAt) {
    if (emittedAt <= _last) return false;
    _last = emittedAt;
    onChanged?.call(emittedAt);
    return true;
  }
}
