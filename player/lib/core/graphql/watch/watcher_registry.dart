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
  /// A rebuilt controller registers its replacement before the old one is
  /// disposed, and the replacement must survive that disposal.
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

  Future<void> invalidate(Iterable<QueryKey> keys) async {
    for (final key in keys) {
      final watcher = _registry.find(key);
      if (watcher != null) {
        await watcher.refetch();
      } else {
        await _fetchLog.clear(key);
      }
    }
  }

  /// Used on app resume: every dormant screen becomes cold, every live one
  /// refetches now.
  Future<void> invalidateAll() async {
    await _fetchLog.clearAll();
    for (final watcher in _registry.watchers) {
      await watcher.refetch();
    }
  }
}

final Provider<Invalidator> invalidatorProvider = Provider<Invalidator>(
  (ref) => Invalidator(
    registry: ref.watch(watcherRegistryProvider),
    fetchLog: ref.watch(fetchLogProvider),
  ),
);
