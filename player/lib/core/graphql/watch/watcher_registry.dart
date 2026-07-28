import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'fetch_log.dart';
import 'query_key.dart';
import 'query_watcher.dart';

/// The watchers that are alive right now, by key.
///
/// A plain mutable object rather than provider state: watchers register from
/// inside a notifier's `build()`, and mutating provider state there is not
/// allowed.
class WatcherRegistry {
  final Map<QueryKey, QueryWatcher<dynamic>> _watchers = {};

  void register(QueryKey key, QueryWatcher<dynamic> watcher) {
    _watchers[key] = watcher;
  }

  /// Removes [watcher] only if it is still the one registered under [key].
  /// Riverpod 3.1.0 actually disposes a predecessor before building its
  /// replacement, so this identity check is a no-op in practice: nothing
  /// else has registered under [key] yet when the predecessor's dispose
  /// callback runs. It stays as a defensive guard against the reverse
  /// order — a replacement registering before its predecessor is torn
  /// down — so a live successor can never be dropped by a stale
  /// predecessor's teardown.
  void unregister(QueryKey key, QueryWatcher<dynamic> watcher) {
    if (identical(_watchers[key], watcher)) {
      _watchers.remove(key);
    }
  }

  QueryWatcher<dynamic>? find(QueryKey key) => _watchers[key];

  Iterable<QueryWatcher<dynamic>> get watchers => _watchers.values.toList();
}

final Provider<WatcherRegistry> watcherRegistryProvider =
    Provider<WatcherRegistry>((ref) => WatcherRegistry());

/// Two-branch invalidation.
///
/// - Live watcher: refetch. The user watches it update, tier-1 line running.
/// - No live watcher: clear that key's fetch-log entry, so the next mount is
///   treated as cold and does `networkOnly` plus shimmer.
class Invalidator {
  Invalidator({required WatcherRegistry registry, required FetchLog fetchLog})
      : _registry = registry,
        _fetchLog = fetchLog;

  final WatcherRegistry _registry;
  final FetchLog _fetchLog;

  /// Invalidates each key in turn.
  ///
  /// Each key is isolated in its own try/catch: `HiveFetchLog.clear` can
  /// throw on an I/O error, and one throw must not abort the rest of the
  /// batch — a favorite toggle invalidating `{favorites, home, tvShowsList}`
  /// has to keep going even if the first key's write fails, or the other two
  /// silently stay stale. The loop stays sequential on purpose: concurrent
  /// refetches over what may be a p2p relay are not wanted here.
  Future<void> invalidate(Iterable<QueryKey> keys) async {
    for (final key in keys) {
      try {
        final watcher = _registry.find(key);
        if (watcher != null) {
          await watcher.refetch();
        } else {
          await _fetchLog.clear(key);
        }
      } catch (error, stackTrace) {
        debugPrint(
          'Invalidator.invalidate: failed to invalidate $key: $error\n'
          '$stackTrace',
        );
      }
    }
  }

  /// Used on app resume: every dormant screen becomes cold, every live one
  /// refetches now.
  ///
  /// Same per-watcher isolation as [invalidate], and for the same reason:
  /// one watcher's refetch failing must not stop the rest from refreshing.
  Future<void> invalidateAll() async {
    await _fetchLog.clearAll();
    for (final watcher in _registry.watchers) {
      try {
        await watcher.refetch();
      } catch (error, stackTrace) {
        debugPrint(
          'Invalidator.invalidateAll: failed to refetch ${watcher.key}: '
          '$error\n$stackTrace',
        );
      }
    }
  }
}

final Provider<Invalidator> invalidatorProvider = Provider<Invalidator>(
  (ref) => Invalidator(
    registry: ref.watch(watcherRegistryProvider),
    fetchLog: ref.watch(fetchLogProvider),
  ),
);
