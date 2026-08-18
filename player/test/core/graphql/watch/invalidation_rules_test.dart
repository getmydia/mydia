import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/invalidation_rules.dart';
import 'package:player/core/graphql/watch/query_key.dart';

void main() {
  group('watchedChanged', () {
    test('invalidates the show grid so poster counts do not go stale', () {
      final keys = InvalidationRules.watchedChanged(showId: 's1');

      expect(keys, contains(QueryKeys.tvShowsList));
    });

    test('invalidates the list-scoped favorites and unwatched keys', () {
      final keys = InvalidationRules.watchedChanged(showId: 's1');

      expect(keys, contains(QueryKeys.favoritesList));
      expect(keys, contains(QueryKeys.unwatchedList));
    });
  });

  group('movieWatchedChanged', () {
    test('invalidates the list-scoped favorites and unwatched keys', () {
      final keys = InvalidationRules.movieWatchedChanged(movieId: 'm1');

      expect(keys, contains(QueryKeys.favoritesList));
      expect(keys, contains(QueryKeys.unwatchedList));
    });
  });

  group('playbackFinished', () {
    test('invalidates every grid that now renders watch state', () {
      final keys = InvalidationRules.playbackFinished(
        mediaType: 'episode',
        mediaId: 'e1',
        showId: 's1',
      );

      expect(keys, contains(QueryKeys.tvShowsList));
      expect(keys, contains(QueryKeys.moviesList));
      expect(keys, contains(QueryKeys.favoritesList));
      expect(keys, contains(QueryKeys.unwatchedList));
    });
  });

  group('progressSynced', () {
    test('still invalidates nothing', () {
      expect(InvalidationRules.progressSynced, isEmpty);
    });
  });

  group('the Continue Watching screen', () {
    test('is refreshed when an episode is marked watched', () {
      final keys = InvalidationRules.watchedChanged(showId: 's1');

      expect(keys, contains(QueryKeys.continueWatchingList));
    });

    test('is refreshed when a movie is marked watched', () {
      final keys = InvalidationRules.movieWatchedChanged(movieId: 'm1');

      expect(keys, contains(QueryKeys.continueWatchingList));
    });

    test('is refreshed when playback finishes', () {
      final keys = InvalidationRules.playbackFinished(
        mediaType: 'episode',
        mediaId: 'e1',
        showId: 's1',
      );

      expect(keys, contains(QueryKeys.continueWatchingList));
    });
  });

  group('the Recently Added screen', () {
    test('is refreshed when an episode is marked watched', () {
      final keys = InvalidationRules.watchedChanged(showId: 's1');

      expect(keys, contains(QueryKeys.recentlyAdded));
    });

    test('is refreshed when a movie is marked watched', () {
      final keys = InvalidationRules.movieWatchedChanged(movieId: 'm1');

      expect(keys, contains(QueryKeys.recentlyAdded));
    });

    test('is refreshed when playback finishes', () {
      final keys = InvalidationRules.playbackFinished(
        mediaType: 'movie',
        mediaId: 'm1',
      );

      expect(keys, contains(QueryKeys.recentlyAdded));
    });
  });
}
