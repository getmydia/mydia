/// One cached source call: emits the stored answer when the fetch log still
/// trusts it, always fetches, and stores what comes back.
///
/// The source twin of `QueryWatcher`. Same contract with the registry and
/// the invalidator (see `CacheWatcher`), same freshness reporting, but it
/// wraps any `Future<T> Function()` and keeps its own JSON store instead of
/// a normalized GraphQL cache.
library;

import 'dart:async';

import 'package:collection/collection.dart' show DeepCollectionEquality;
import 'package:flutter/foundation.dart' show debugPrint;

import '../../graphql/watch/cache_watcher.dart';
import '../../graphql/watch/fetch_log.dart';
import '../../graphql/watch/freshness.dart';
import '../../graphql/watch/query_key.dart';
import 'source_cache.dart';

class SourceWatcher<T> implements CacheWatcher {
  SourceWatcher({
    required this.key,
    required Future<T> Function() fetch,
    required SourceCache cache,
    required FetchLog fetchLog,
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
    this.maxAge = kFreshnessThreshold,
    this.onFreshness,
    this.canRefetch,
    DateTime Function() clock = DateTime.now,
  })  : _fetch = fetch,
        _cache = cache,
        _fetchLog = fetchLog,
        _encode = encode,
        _decode = decode,
        _clock = clock {
    unawaited(_start());
  }

  @override
  final QueryKey key;
  final Duration maxAge;
  final void Function(Freshness freshness)? onFreshness;

  /// Guards automatic refetches only, exactly as in `QueryWatcher`.
  final bool Function()? canRefetch;

  final Future<T> Function() _fetch;
  final SourceCache _cache;
  final FetchLog _fetchLog;
  final Object? Function(T value) _encode;
  final T Function(Object? json) _decode;
  final DateTime Function() _clock;

  /// Owned rather than an `async*` generator, which would close on the
  /// first error.
  final StreamController<T> _controller = StreamController<T>.broadcast();

  /// Completes once the cached value (if any) has gone out, so a refetch
  /// requested before that cannot overtake it.
  final Completer<void> _ready = Completer<void>();

  /// Completes on [close], releasing refetches still waiting on a fetch.
  final Completer<void> _closeSignal = Completer<void>();

  Future<void>? _inFlight;
  Future<void>? _rerun;
  bool _hasData = false;
  bool _closed = false;

  /// The JSON of the last value that went out, from the cache or a fetch.
  bool _hasEmitted = false;
  Object? _lastEncoded;
  static const DeepCollectionEquality _equality = DeepCollectionEquality();

  Stream<T> get stream => _controller.stream;

  Future<void> _start() async {
    // The owner subscribes to [stream] after construction returns.
    await Future<void>.value();
    if (_closed) return;

    final fetchedAt = _fetchLog.lastFetchedAt(key);
    // No fetch-log time means never fetched or invalidated: a cold mount,
    // even when an entry is still stored.
    if (fetchedAt != null) {
      final cached = _readCache();
      if (cached != null) {
        _hasData = true;
        _add(cached.value);
      }
    }
    if (!_ready.isCompleted) _ready.complete();
    await _refresh();
  }

  ({T value, DateTime writtenAt})? _readCache() {
    final entry = _cache.read(key);
    if (entry == null) return null;
    try {
      return (value: _decode(entry.json), writtenAt: entry.writtenAt);
    } catch (error) {
      debugPrint('[SourceWatcher] dropping unreadable $key: $error');
      unawaited(_cache.delete(key).catchError((Object e) {
        debugPrint('[SourceWatcher] could not drop $key: $e');
      }));
      return null;
    }
  }

  /// One fetch at a time. Automatic callers and the initial load join the
  /// running one; [refetch] queues a follow-up instead.
  Future<void> _refresh() =>
      _inFlight ??= _fetchOnce().whenComplete(() => _inFlight = null);

  Future<void> _fetchOnce() async {
    _publish(fetchedAt: _fetchLog.lastFetchedAt(key), isRefreshing: true);
    final T value;
    try {
      value = await _fetch();
    } catch (error, stackTrace) {
      if (!_closed) _onFailure(error, stackTrace);
      return;
    }
    if (_closed) return;

    final now = _clock();
    _hasData = true;
    Object? encoded;
    try {
      encoded = _encode(value);
    } catch (error) {
      debugPrint('[SourceWatcher] could not encode $key: $error');
    }
    // An answer equal to what is already out would only make every
    // dependent rebuild; the models define no `==`, so compare the JSON.
    final unchanged = _hasEmitted &&
        encoded != null &&
        _equality.equals(encoded, _lastEncoded);
    if (!unchanged) _add(value, encoded);
    _publish(fetchedAt: now);
    try {
      // Data first, then the log: the log must never vouch for an entry
      // that failed to store.
      await _cache.write(key, encoded ?? _encode(value), now);
      await _fetchLog.record(key, now);
    } catch (error) {
      debugPrint('[SourceWatcher] could not store $key: $error');
    }
  }

  void _onFailure(Object error, StackTrace stackTrace) {
    if (_hasData) {
      _publish(
        fetchedAt: _fetchLog.lastFetchedAt(key) ?? _cache.read(key)?.writtenAt,
        refreshFailed: true,
      );
      return;
    }
    // Invalidated or never trusted, but something is stored: better than an
    // error screen when the server cannot be reached.
    final cached = _readCache();
    if (cached != null) {
      _hasData = true;
      _add(cached.value);
      _publish(fetchedAt: cached.writtenAt, refreshFailed: true);
      return;
    }
    _publish(fetchedAt: null);
    if (!_controller.isClosed) _controller.addError(error, stackTrace);
  }

  void _publish({
    required DateTime? fetchedAt,
    bool isRefreshing = false,
    bool refreshFailed = false,
  }) {
    if (_closed) return;
    onFreshness?.call(Freshness(
      fetchedAt: fetchedAt,
      isRefreshing: isRefreshing && _hasData,
      refreshFailed: refreshFailed && _hasData,
      isStale: fetchedAt == null || _clock().difference(fetchedAt) > maxAge,
      hasData: _hasData,
    ));
  }

  void _add(T value, [Object? encoded]) {
    _hasEmitted = true;
    _lastEncoded = encoded ?? _tryEncode(value);
    if (!_controller.isClosed) _controller.add(value);
  }

  Object? _tryEncode(T value) {
    try {
      return _encode(value);
    } catch (_) {
      return null;
    }
  }

  /// Fetches now. Always honoured; this is the user's refresh.
  ///
  /// A refetch that arrives mid-fetch does not join it: the running request
  /// may predate the write that asked for this one, and its answer would be
  /// stamped fresh. It queues exactly one follow-up instead, shared by every
  /// refetch that arrives during the same fetch.
  Future<void> refetch() async {
    if (_closed) return;
    await _ready.future;
    if (_closed) return;
    final running = _inFlight;
    if (running == null) {
      await Future.any([_refresh(), _closeSignal.future]);
      return;
    }
    _rerun ??= running.then((_) {
      _rerun = null;
      return _closed ? null : _refresh();
    });
    await Future.any([_rerun!, _closeSignal.future]);
  }

  @override
  Future<bool> refetchAutomatically() async {
    final allowed = canRefetch == null || canRefetch!();
    if (!allowed) return false;
    await refetch();
    return true;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_ready.isCompleted) _ready.complete();
    if (!_closeSignal.isCompleted) _closeSignal.complete();
    await _controller.close();
  }
}
