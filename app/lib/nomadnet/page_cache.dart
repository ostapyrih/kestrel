import 'dart:typed_data';

/// Storage behind [PageCache].
abstract class PageCacheStore {
  /// Returns (data, expiresAtMs) for [url], or null.
  Future<(Uint8List, int)?> read(String url);
  Future<void> write(String url, Uint8List data, int expiresAtMs);
  Future<void> delete(String url);

  /// Deletes every entry expiring at or before [nowMs].
  Future<void> deleteExpired(int nowMs);
}

/// In-memory [PageCacheStore] (tests, fallback).
class MemoryPageCacheStore implements PageCacheStore {
  final Map<String, (Uint8List, int)> entries = {};

  @override
  Future<(Uint8List, int)?> read(String url) async => entries[url];

  @override
  Future<void> write(String url, Uint8List data, int expiresAtMs) async =>
      entries[url] = (data, expiresAtMs);

  @override
  Future<void> delete(String url) async => entries.remove(url);

  @override
  Future<void> deleteExpired(int nowMs) async =>
      entries.removeWhere((_, v) => v.$2 <= nowMs);
}

/// NomadNet's page cache (`Browser.get_cached` / `cache_page`): a page is
/// cached for the seconds given by its `#!c=` header (default 12 h, `0` =
/// never); expired entries are never returned. Only requests without
/// request data are looked up (NomadNet skips the cache for forms and link
/// variables).
class PageCache {
  PageCache(this.store, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final PageCacheStore store;
  final DateTime Function() _now;

  int get _nowMs => _now().millisecondsSinceEpoch;

  /// The cached page for [url], or null if absent or expired.
  Future<Uint8List?> get(String url) async {
    final e = await store.read(url);
    if (e == null) return null;
    if (e.$2 <= _nowMs) {
      await store.delete(url);
      return null;
    }
    return e.$1;
  }

  /// Caches [data] for [seconds]; zero or negative removes any old entry and
  /// stores nothing.
  Future<void> put(String url, Uint8List data, int seconds) async {
    if (seconds <= 0) {
      await store.delete(url);
      return;
    }
    await store.write(url, data, _nowMs + seconds * 1000);
  }

  Future<void> remove(String url) => store.delete(url);

  Future<void> purgeExpired() => store.deleteExpired(_nowMs);
}
