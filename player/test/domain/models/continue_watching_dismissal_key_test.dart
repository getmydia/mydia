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
}
