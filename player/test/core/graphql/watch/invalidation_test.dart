import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/graphql/watch/invalidation_rules.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/core/graphql/watch/query_watcher.dart';
import 'package:player/core/graphql/watch/watcher_registry.dart';

import '../../../test_utils/stub_graphql_client.dart';

const String _pingQuery = r'''
query Ping {
  ping {
    id
    value
  }
}
''';

Map<String, dynamic> _pingData(String value) => {
      '__typename': 'Query',
      'ping': {'__typename': 'Ping', 'id': 'ping-1', 'value': value},
    };

void main() {
  group('InvalidationRules', () {
    test('toggling a show favorite refreshes favorites, home and the show list',
        () {
      final keys = InvalidationRules.favoriteToggled(isMovie: false);

      expect(keys, contains(QueryKeys.favorites));
      expect(keys, contains(QueryKeys.home));
      expect(keys, contains(QueryKeys.tvShowsList));
      expect(keys, isNot(contains(QueryKeys.moviesList)));
    });

    test('toggling a movie favorite refreshes the movie list, not the shows',
        () {
      final keys = InvalidationRules.favoriteToggled(isMovie: true);

      expect(keys, contains(QueryKeys.moviesList));
      expect(keys, isNot(contains(QueryKeys.tvShowsList)));
    });

    test('marking watched refreshes home, unwatched and that show', () {
      final keys = InvalidationRules.watchedChanged(showId: '7');

      expect(keys, {
        QueryKeys.home,
        QueryKeys.unwatched,
        QueryKeys.showDetail('7'),
      });
    });

    test('progress sync invalidates nothing', () {
      // The 10s sync timer would otherwise refetch Home hundreds of times per
      // movie, over what may be a p2p relay.
      expect(InvalidationRules.progressSynced, isEmpty);
    });

    test('finishing a movie refreshes home, unwatched and that movie', () {
      final keys = InvalidationRules.playbackFinished(
        mediaType: 'movie',
        mediaId: 'm1',
      );

      expect(keys, {
        QueryKeys.home,
        QueryKeys.unwatched,
        QueryKeys.movieDetail('m1'),
      });
    });

    test('finishing an episode also refreshes its show when known', () {
      final keys = InvalidationRules.playbackFinished(
        mediaType: 'episode',
        mediaId: 'e1',
        showId: 's1',
      );

      expect(keys, contains(QueryKeys.episodeDetail('e1')));
      expect(keys, contains(QueryKeys.showDetail('s1')));
    });
  });

  group('Invalidator', () {
    QueryWatcher<String> makeWatcher(StubLink link, FetchLog log) {
      return QueryWatcher<String>(
        key: QueryKeys.home,
        client: Future<GraphQLClient>.value(stubClient(link)),
        fetchLog: log,
        document: gql(_pingQuery),
        parse: (data) =>
            (data['ping'] as Map<String, dynamic>)['value'] as String,
      );
    }

    test('a live watcher is refetched', () async {
      final log = InMemoryFetchLog();
      var call = 0;
      final link = StubLink((_, __) {
        call++;
        return _pingData('v$call');
      });
      final watcher = makeWatcher(link, log);
      addTearDown(watcher.close);

      final registry = WatcherRegistry()..register(QueryKeys.home, watcher);
      final invalidator = Invalidator(registry: registry, fetchLog: log);

      await watcher.stream.first;
      await invalidator.invalidate([QueryKeys.home]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(link.requests.length, greaterThanOrEqualTo(2));
      expect(log.lastFetchedAt(QueryKeys.home), isNotNull);
    });

    test('a dormant key has its fetch-log entry cleared instead', () async {
      final log = InMemoryFetchLog({
        QueryKeys.unwatched: DateTime(2026, 7, 28),
      });
      final invalidator =
          Invalidator(registry: WatcherRegistry(), fetchLog: log);

      await invalidator.invalidate([QueryKeys.unwatched]);

      expect(log.lastFetchedAt(QueryKeys.unwatched), isNull);
    });

    test('invalidateAll clears the log and refetches every live watcher',
        () async {
      final log = InMemoryFetchLog({
        QueryKeys.unwatched: DateTime(2026, 7, 28),
      });
      final link = StubLink((_, __) => _pingData('v'));
      final watcher = makeWatcher(link, log);
      addTearDown(watcher.close);

      final registry = WatcherRegistry()..register(QueryKeys.home, watcher);
      final invalidator = Invalidator(registry: registry, fetchLog: log);

      await watcher.stream.first;
      await invalidator.invalidateAll();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(log.lastFetchedAt(QueryKeys.unwatched), isNull);
      expect(link.requests.length, greaterThanOrEqualTo(2));
    });

    test('unregister only removes the watcher it was given', () async {
      final log = InMemoryFetchLog();
      final first = makeWatcher(StubLink((_, __) => _pingData('a')), log);
      final second = makeWatcher(StubLink((_, __) => _pingData('b')), log);
      addTearDown(first.close);
      addTearDown(second.close);

      final registry = WatcherRegistry()..register(QueryKeys.home, second);
      registry.unregister(QueryKeys.home, first);

      expect(registry.find(QueryKeys.home), same(second));
    });

    test('the providers wire the registry and log together', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(invalidatorProvider), isA<Invalidator>());
      expect(container.read(watcherRegistryProvider), isA<WatcherRegistry>());
    });
  });
}
