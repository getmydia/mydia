import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/graphql/watch/freshness.dart';
import 'package:player/core/graphql/watch/query_key.dart';

QueryResult<dynamic> _result({
  Map<String, dynamic>? data,
  bool loading = false,
  bool failed = false,
}) {
  return QueryResult<dynamic>(
    options: QueryOptions<dynamic>(document: gql('query Q { x }')),
    source: loading ? QueryResultSource.loading : QueryResultSource.network,
    data: data,
    // OperationException has mutable fields, so it is not const-constructible.
    exception: failed
        ? OperationException(
            graphqlErrors: [const GraphQLError(message: 'boom')],
          )
        : null,
  );
}

void main() {
  final now = DateTime(2026, 7, 28, 12, 0);

  group('Freshness.from', () {
    test('a loading result with data on screen is refreshing', () {
      final freshness = Freshness.from(
        result: _result(data: const {'x': 1}, loading: true),
        fetchedAt: now.subtract(const Duration(minutes: 1)),
        maxAge: kFreshnessThreshold,
        now: now,
      );

      expect(freshness.isRefreshing, isTrue);
      expect(freshness.refreshFailed, isFalse);
    });

    test('a loading result with no data yet is not refreshing', () {
      final freshness = Freshness.from(
        result: _result(loading: true),
        fetchedAt: null,
        maxAge: kFreshnessThreshold,
        now: now,
      );

      expect(freshness.isRefreshing, isFalse);
    });

    test('an exception carrying data forward is a failed refresh', () {
      final freshness = Freshness.from(
        result: _result(data: const {'x': 1}, failed: true),
        fetchedAt: now.subtract(const Duration(minutes: 1)),
        maxAge: kFreshnessThreshold,
        now: now,
      );

      expect(freshness.refreshFailed, isTrue);
    });

    test('an exception with no data is not a failed refresh (it is an error)',
        () {
      final freshness = Freshness.from(
        result: _result(failed: true),
        fetchedAt: null,
        maxAge: kFreshnessThreshold,
        now: now,
      );

      expect(freshness.refreshFailed, isFalse);
    });

    test('age past the threshold is stale, under it is fresh', () {
      Freshness at(Duration age) => Freshness.from(
            result: _result(data: const {'x': 1}),
            fetchedAt: now.subtract(age),
            maxAge: kFreshnessThreshold,
            now: now,
          );

      expect(at(const Duration(minutes: 4)).isStale, isFalse);
      expect(at(const Duration(minutes: 6)).isStale, isTrue);
    });

    test('a missing fetch timestamp is infinitely stale', () {
      final freshness = Freshness.from(
        result: _result(data: const {'x': 1}),
        fetchedAt: null,
        maxAge: kFreshnessThreshold,
        now: now,
      );

      expect(freshness.isStale, isTrue);
      expect(freshness.fetchedAt, isNull);
    });
  });

  group('Freshness.combine', () {
    test('combining is optimistic about time and pessimistic about state', () {
      final older = now.subtract(const Duration(hours: 2));
      final combined = Freshness.combine([
        Freshness(fetchedAt: now, isStale: false),
        Freshness(fetchedAt: older, isStale: true, refreshFailed: true),
      ]);

      expect(combined.fetchedAt, older, reason: 'oldest wins');
      expect(combined.isStale, isTrue);
      expect(combined.refreshFailed, isTrue);
    });

    test('combining nothing yields an empty freshness', () {
      expect(Freshness.combine(const []), const Freshness());
    });
  });

  group('FreshnessRegistry', () {
    test('publish exposes state per key and clear removes it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final registry = container.read(freshnessRegistryProvider.notifier);
      const state = Freshness(isRefreshing: true);

      registry.publish(QueryKeys.home, state);
      expect(container.read(freshnessRegistryProvider)[QueryKeys.home], state);

      registry.clear(QueryKeys.home);
      expect(container.read(freshnessRegistryProvider)[QueryKeys.home], isNull);
    });
  });
}
