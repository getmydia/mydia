// Which media item "Remove from Continue Watching" actually hides.
//
// The rail's cards are episodes but its dismissals are shows, and every layer
// above this — the menu's target, the optimistic splice in both controllers,
// the mutation argument — reads the answer from here. Getting it wrong is
// silent: matching on the card's own id simply never removes an episode card,
// and the server refuses an episode id outright.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/continue_watching_item.dart';

void main() {
  group('ContinueWatchingItem.continueWatchingKey', () {
    test('a movie is hidden by its own id', () {
      const item = ContinueWatchingItem(
        id: 'mv-1',
        type: 'movie',
        title: 'Heat',
      );

      expect(item.continueWatchingKey, 'mv-1');
    });

    test('an episode is hidden by its show, not itself', () {
      const item = ContinueWatchingItem(
        id: 'ep-1',
        type: 'episode',
        title: 'System',
        showId: 'show-1',
      );

      expect(item.continueWatchingKey, 'show-1');
      expect(item.continueWatchingKey, isNot('ep-1'));
    });

    // Falling back to the episode id here would send the server the one id it
    // rejects, so a card with no show offers no removal at all.
    test('an episode with no known show has nothing to hide', () {
      const item = ContinueWatchingItem(
        id: 'ep-1',
        type: 'episode',
        title: 'System',
      );

      expect(item.continueWatchingKey, isNull);
    });

    test('a next-up card keys on its show like any other episode', () {
      const item = ContinueWatchingItem(
        id: 'ep-2',
        type: 'episode',
        title: 'Sheridan',
        showId: 'show-1',
        state: 'next',
      );

      expect(item.continueWatchingKey, 'show-1');
    });
  });

  group('ContinueWatchingItem.dismissedBy', () {
    const movie = ContinueWatchingItem(
      id: 'mv-1',
      type: 'movie',
      title: 'Heat',
    );

    const episode = ContinueWatchingItem(
      id: 'ep-1',
      type: 'episode',
      title: 'System',
      showId: 'show-1',
    );

    test('an episode card is dismissed by its show id', () {
      expect(episode.dismissedBy('show-1'), isTrue);
    });

    test('an episode card is not dismissed by its own id', () {
      expect(episode.dismissedBy('ep-1'), isFalse);
    });

    test('a movie card is dismissed by its own id', () {
      expect(movie.dismissedBy('mv-1'), isTrue);
    });

    test('an unrelated title is left alone', () {
      expect(movie.dismissedBy('show-1'), isFalse);
      expect(episode.dismissedBy('show-2'), isFalse);
    });
  });

  group('restoreFailedRemoval', () {
    ContinueWatchingItem movie(String id) =>
        ContinueWatchingItem(id: id, type: 'movie', title: id);

    test('puts the failed card back where it was', () {
      final snapshot = [movie('a'), movie('b'), movie('c')];
      final latest = [movie('a'), movie('c')];

      final restored = restoreFailedRemoval(
        snapshot: snapshot,
        latest: latest,
        key: 'b',
      );

      expect(restored.map((item) => item.id), ['a', 'b', 'c']);
    });

    // The defect a whole-snapshot restore has: the viewer removed b and then
    // c, c succeeded, b failed. Restoring the snapshot would bring c back too.
    test('does not resurrect a card another removal has since dismissed', () {
      final snapshot = [movie('a'), movie('b'), movie('c')];
      final latest = [movie('a')];

      final restored = restoreFailedRemoval(
        snapshot: snapshot,
        latest: latest,
        key: 'b',
      );

      expect(restored.map((item) => item.id), ['a', 'b']);
      expect(restored.map((item) => item.id), isNot(contains('c')));
    });

    // A successful removal invalidates and refetches, so the list can gain
    // cards while a failing mutation is still in flight.
    test('keeps a card a refetch added meanwhile', () {
      final snapshot = [movie('a'), movie('b')];
      final latest = [movie('a'), movie('d')];

      final restored = restoreFailedRemoval(
        snapshot: snapshot,
        latest: latest,
        key: 'b',
      );

      expect(restored.map((item) => item.id), ['a', 'b', 'd']);
    });

    test('an episode is restored by its show key', () {
      final snapshot = [
        movie('a'),
        const ContinueWatchingItem(
          id: 'ep-1',
          type: 'episode',
          title: 'System',
          showId: 'show-1',
        ),
      ];
      final latest = [movie('a')];

      final restored = restoreFailedRemoval(
        snapshot: snapshot,
        latest: latest,
        key: 'show-1',
      );

      expect(restored.map((item) => item.id), ['a', 'ep-1']);
    });

    test('nothing to restore leaves the latest list alone', () {
      final snapshot = [movie('a'), movie('b')];
      final latest = [movie('a'), movie('b')];

      final restored = restoreFailedRemoval(
        snapshot: snapshot,
        latest: latest,
        key: 'zzz',
      );

      expect(restored.map((item) => item.id), ['a', 'b']);
    });
  });
}
