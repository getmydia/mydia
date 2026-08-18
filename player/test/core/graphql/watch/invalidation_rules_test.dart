import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/invalidation_rules.dart';
import 'package:player/core/graphql/watch/invalidation_target.dart';
import 'package:player/core/graphql/watch/query_key.dart';

void main() {
  group('watchedChanged', () {
    test('invalidates the show grid so poster counts do not go stale', () {
      final keys = InvalidationRules.watchedChanged(showId: 's1');

      expect(keys, contains(QueryKeys.tvShowsList.target));
    });

    test('invalidates the list-scoped favorites and unwatched keys', () {
      final keys = InvalidationRules.watchedChanged(showId: 's1');

      expect(keys, contains(QueryKeys.favoritesList.target));
      expect(keys, contains(QueryKeys.unwatchedList.target));
    });
  });

  group('movieWatchedChanged', () {
    test('invalidates the list-scoped favorites and unwatched keys', () {
      final keys = InvalidationRules.movieWatchedChanged(movieId: 'm1');

      expect(keys, contains(QueryKeys.favoritesList.target));
      expect(keys, contains(QueryKeys.unwatchedList.target));
    });
  });

  group('playbackFinished', () {
    test('invalidates every grid that now renders watch state', () {
      final keys = InvalidationRules.playbackFinished(
        mediaType: 'episode',
        mediaId: 'e1',
        showId: 's1',
      );

      expect(keys, contains(QueryKeys.tvShowsList.target));
      expect(keys, contains(QueryKeys.moviesList.target));
      expect(keys, contains(QueryKeys.favoritesList.target));
      expect(keys, contains(QueryKeys.unwatchedList.target));
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

      expect(keys, contains(QueryKeys.continueWatchingList.target));
    });

    test('is refreshed when a movie is marked watched', () {
      final keys = InvalidationRules.movieWatchedChanged(movieId: 'm1');

      expect(keys, contains(QueryKeys.continueWatchingList.target));
    });

    test('is refreshed when playback finishes', () {
      final keys = InvalidationRules.playbackFinished(
        mediaType: 'episode',
        mediaId: 'e1',
        showId: 's1',
      );

      expect(keys, contains(QueryKeys.continueWatchingList.target));
    });
  });

  group('the Recently Added screen', () {
    test('is refreshed when an episode is marked watched', () {
      final keys = InvalidationRules.watchedChanged(showId: 's1');

      expect(keys, contains(QueryKeys.recentlyAdded.target));
    });

    test('is refreshed when a movie is marked watched', () {
      final keys = InvalidationRules.movieWatchedChanged(movieId: 'm1');

      expect(keys, contains(QueryKeys.recentlyAdded.target));
    });

    test('is refreshed when playback finishes', () {
      final keys = InvalidationRules.playbackFinished(
        mediaType: 'movie',
        mediaId: 'm1',
      );

      expect(keys, contains(QueryKeys.recentlyAdded.target));
    });
  });

  group('the Favorites screen', () {
    test('is refreshed when an episode is marked watched', () {
      final keys = InvalidationRules.watchedChanged(showId: 's1');

      expect(keys, contains(QueryKeys.favorites.target));
    });

    test('is refreshed when a movie is marked watched', () {
      final keys = InvalidationRules.movieWatchedChanged(movieId: 'm1');

      expect(keys, contains(QueryKeys.favorites.target));
    });

    test('is refreshed when playback finishes for an episode', () {
      final keys = InvalidationRules.playbackFinished(
        mediaType: 'episode',
        mediaId: 'e1',
        showId: 's1',
      );

      expect(keys, contains(QueryKeys.favorites.target));
    });

    test('is refreshed when playback finishes for a movie', () {
      final keys = InvalidationRules.playbackFinished(
        mediaType: 'movie',
        mediaId: 'm1',
      );

      expect(keys, contains(QueryKeys.favorites.target));
    });
  });

  group('the collection items family', () {
    test('is invalidated when an episode is marked watched', () {
      final targets = InvalidationRules.watchedChanged(showId: 's1');

      expect(targets, contains(Families.collectionItems));
    });

    test('is invalidated when a movie is marked watched', () {
      final targets = InvalidationRules.movieWatchedChanged(movieId: 'm1');

      expect(targets, contains(Families.collectionItems));
    });

    test('is invalidated when playback finishes', () {
      final targets = InvalidationRules.playbackFinished(
        mediaType: 'movie',
        mediaId: 'm1',
      );

      expect(targets, contains(Families.collectionItems));
    });

    test('is not invalidated by a favorite toggle, which it does not render',
        () {
      final targets = InvalidationRules.favoriteToggled(isMovie: true);

      expect(targets, isNot(contains(Families.collectionItems)));
    });
  });

  group('a favorite toggle', () {
    // Pins the deliberate choice, so a later reader does not "complete" the
    // rule. None of these three selects favorite state, only watchStatus.
    test('touches none of the three watch-state screens', () {
      final targets = InvalidationRules.favoriteToggled(isMovie: false);

      expect(targets, isNot(contains(QueryKeys.continueWatchingList.target)));
      expect(targets, isNot(contains(QueryKeys.recentlyAdded.target)));
      expect(targets, isNot(contains(Families.collectionItems)));
    });
  });
}
