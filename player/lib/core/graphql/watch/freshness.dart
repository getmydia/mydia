import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import 'query_key.dart';

/// How old data may be before a screen treats it as a cold start.
///
/// One constant for the whole app: tuning freshness is a one-line change.
const Duration kFreshnessThreshold = Duration(minutes: 5);

/// What a screen can honestly say about the data it is showing.
@immutable
class Freshness {
  const Freshness({
    this.fetchedAt,
    this.isRefreshing = false,
    this.refreshFailed = false,
    this.isStale = false,
    this.hasData = false,
  });

  /// When this key last reached the network, from the fetch log.
  final DateTime? fetchedAt;

  /// A fetch is in flight over content that is already on screen.
  final bool isRefreshing;

  /// The last fetch failed but previous data is still being shown.
  final bool refreshFailed;

  /// [fetchedAt] is older than the threshold, or missing entirely.
  final bool isStale;

  /// Whether there is actually data on screen right now.
  ///
  /// A cold-stale mount (age gate picks `networkOnly`, first result is
  /// `QueryResult.loading` with `data == null`) is stale by definition but
  /// has nothing to show yet; the header must not claim to be "showing"
  /// anything for it. This is what tells it apart from a screen that really
  /// is showing old data.
  final bool hasData;

  static Freshness from({
    required QueryResult<dynamic> result,
    required DateTime? fetchedAt,
    required Duration maxAge,
    required DateTime now,
    // The watcher alone knows whether this particular emission is the
    // cache-sourced half of a still-pending `cacheAndNetwork` start (see
    // `QueryWatcher._awaitingInitialNetworkResult`). That case has no
    // `QueryResultSource.loading` result to key off, so `result.isLoading`
    // never fires for it; the watcher passes what it knows instead of this
    // method trying to infer fetch-policy history from a bare `QueryResult`.
    bool awaitingNetworkResult = false,
  }) {
    final hasData = result.data != null;
    return Freshness(
      fetchedAt: fetchedAt,
      isRefreshing: (result.isLoading || awaitingNetworkResult) && hasData,
      // carryForwardDataOnException defaults to true, so a failed refresh
      // arrives as "exception plus the previous data".
      refreshFailed: result.hasException && hasData,
      isStale: fetchedAt == null || now.difference(fetchedAt) > maxAge,
      hasData: hasData,
    );
  }

  /// Merges the freshness of several keys shown on one screen.
  ///
  /// Oldest timestamp wins; any key refreshing, failing or stale makes the
  /// whole screen so.
  static Freshness combine(Iterable<Freshness> parts) {
    if (parts.isEmpty) return const Freshness();

    DateTime? oldest;
    var isRefreshing = false;
    var refreshFailed = false;
    var isStale = false;
    var hasData = false;

    for (final part in parts) {
      final at = part.fetchedAt;
      if (at != null && (oldest == null || at.isBefore(oldest))) {
        oldest = at;
      }
      isRefreshing = isRefreshing || part.isRefreshing;
      refreshFailed = refreshFailed || part.refreshFailed;
      isStale = isStale || part.isStale;
      hasData = hasData || part.hasData;
    }

    return Freshness(
      fetchedAt: oldest,
      isRefreshing: isRefreshing,
      refreshFailed: refreshFailed,
      isStale: isStale,
      hasData: hasData,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Freshness &&
          other.fetchedAt == fetchedAt &&
          other.isRefreshing == isRefreshing &&
          other.refreshFailed == refreshFailed &&
          other.isStale == isStale &&
          other.hasData == hasData);

  @override
  int get hashCode =>
      Object.hash(fetchedAt, isRefreshing, refreshFailed, isStale, hasData);

  @override
  String toString() => 'Freshness(fetchedAt: $fetchedAt, '
      'isRefreshing: $isRefreshing, refreshFailed: $refreshFailed, '
      'isStale: $isStale, hasData: $hasData)';
}

/// Freshness for every live query, keyed so screens can select just theirs.
class FreshnessRegistry extends Notifier<Map<QueryKey, Freshness>> {
  @override
  Map<QueryKey, Freshness> build() => const {};

  void publish(QueryKey key, Freshness freshness) {
    // Mirrors the guard in `clear` below: a result can in principle still be
    // in flight (e.g. a pending `unawaited` write) after the container that
    // owns this registry is torn down, and `state` would throw on both the
    // read and the write in that case. Unreachable today — nothing publishes
    // after a watcher's own teardown — but the asymmetry with `clear`
    // invited exactly that assumption, so guard it the same way.
    if (!ref.mounted) return;
    if (state[key] == freshness) return;
    state = {...state, key: freshness};
  }

  void clear(QueryKey key) {
    // A watcher's teardown clears its freshness entry from `ref.onDispose`,
    // deferred to a microtask (see `createWatcher`) to dodge Riverpod's
    // debug-mode dispose-callback assertion. By the time that microtask
    // runs, this registry may itself already be torn down (e.g. the whole
    // container was disposed at once); `state` below would throw in that
    // case, both on the read and the write, so the mounted check must come
    // first.
    if (!ref.mounted) return;
    if (!state.containsKey(key)) return;
    state = {...state}..remove(key);
  }
}

final NotifierProvider<FreshnessRegistry, Map<QueryKey, Freshness>>
    freshnessRegistryProvider =
    NotifierProvider<FreshnessRegistry, Map<QueryKey, Freshness>>(
  FreshnessRegistry.new,
);
