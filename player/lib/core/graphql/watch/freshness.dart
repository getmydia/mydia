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
  });

  /// When this key last reached the network, from the fetch log.
  final DateTime? fetchedAt;

  /// A fetch is in flight over content that is already on screen.
  final bool isRefreshing;

  /// The last fetch failed but previous data is still being shown.
  final bool refreshFailed;

  /// [fetchedAt] is older than the threshold, or missing entirely.
  final bool isStale;

  static Freshness from({
    required QueryResult<dynamic> result,
    required DateTime? fetchedAt,
    required Duration maxAge,
    required DateTime now,
  }) {
    final hasData = result.data != null;
    return Freshness(
      fetchedAt: fetchedAt,
      isRefreshing: result.isLoading && hasData,
      // carryForwardDataOnException defaults to true, so a failed refresh
      // arrives as "exception plus the previous data".
      refreshFailed: result.hasException && hasData,
      isStale: fetchedAt == null || now.difference(fetchedAt) > maxAge,
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

    for (final part in parts) {
      final at = part.fetchedAt;
      if (at != null && (oldest == null || at.isBefore(oldest))) {
        oldest = at;
      }
      isRefreshing = isRefreshing || part.isRefreshing;
      refreshFailed = refreshFailed || part.refreshFailed;
      isStale = isStale || part.isStale;
    }

    return Freshness(
      fetchedAt: oldest,
      isRefreshing: isRefreshing,
      refreshFailed: refreshFailed,
      isStale: isStale,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Freshness &&
          other.fetchedAt == fetchedAt &&
          other.isRefreshing == isRefreshing &&
          other.refreshFailed == refreshFailed &&
          other.isStale == isStale);

  @override
  int get hashCode =>
      Object.hash(fetchedAt, isRefreshing, refreshFailed, isStale);

  @override
  String toString() => 'Freshness(fetchedAt: $fetchedAt, '
      'isRefreshing: $isRefreshing, refreshFailed: $refreshFailed, '
      'isStale: $isStale)';
}

/// Freshness for every live query, keyed so screens can select just theirs.
class FreshnessRegistry extends Notifier<Map<QueryKey, Freshness>> {
  @override
  Map<QueryKey, Freshness> build() => const {};

  void publish(QueryKey key, Freshness freshness) {
    if (state[key] == freshness) return;
    state = {...state, key: freshness};
  }

  void clear(QueryKey key) {
    if (!state.containsKey(key)) return;
    state = {...state}..remove(key);
  }
}

final NotifierProvider<FreshnessRegistry, Map<QueryKey, Freshness>>
    freshnessRegistryProvider =
    NotifierProvider<FreshnessRegistry, Map<QueryKey, Freshness>>(
  FreshnessRegistry.new,
);
