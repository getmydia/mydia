// The long-press menu's visibility rules, asserted as pure logic.
//
// mediaContextActionsFor is deliberately a plain function rather than a widget
// concern: what a card's menu offers depends only on the target, so the rules
// are tested without pumping a menu, and showMediaContextMenu is left with
// nothing but presentation and routing.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/media_context_menu.dart';

void main() {
  group('mediaContextActionsFor', () {
    test('an Up Next episode offers play, its show, and its own details', () {
      const target = MediaContextTarget(
        id: 'ep-1',
        type: 'episode',
        showId: 'show-1',
        hasFile: true,
        tapPlays: true,
      );

      expect(mediaContextActionsFor(target), [
        MediaContextAction.play,
        MediaContextAction.goToShow,
        MediaContextAction.episodeDetails,
      ]);
    });

    test('a Continue Watching movie offers play and its own details', () {
      const target = MediaContextTarget(
        id: 'mv-1',
        type: 'movie',
        hasFile: true,
        tapPlays: true,
      );

      expect(mediaContextActionsFor(target), [
        MediaContextAction.play,
        MediaContextAction.movieDetails,
      ]);
    });

    test('a target with no playable file offers no play', () {
      const target = MediaContextTarget(
        id: 'ep-2',
        type: 'episode',
        showId: 'show-1',
        tapPlays: true,
      );

      expect(
        mediaContextActionsFor(target),
        isNot(contains(MediaContextAction.play)),
      );
    });

    test('an episode with no known show omits Go to show', () {
      const target = MediaContextTarget(
        id: 'ep-3',
        type: 'episode',
        hasFile: true,
        tapPlays: true,
      );

      expect(
        mediaContextActionsFor(target),
        isNot(contains(MediaContextAction.goToShow)),
      );
    });

    // A card whose tap already opens the title earns nothing from a menu that
    // would only offer to open the title, so it gets no menu at all. This is
    // what keeps the Recently Added and Favorites rails untouched.
    test('a movie whose tap already navigates earns an empty menu', () {
      const target = MediaContextTarget(id: 'mv-2', type: 'movie');

      expect(mediaContextActionsFor(target), isEmpty);
    });

    // Regression for the two holes left by gating only movieDetails on
    // tapPlays. A playable episode on a rail with no play handler used to be
    // offered Play, which routes through a nullable onItemActivate and would
    // have done nothing, plus an Episode details entry duplicating its own tap.
    test('a playable episode whose tap navigates earns an empty menu', () {
      const target = MediaContextTarget(
        id: 'ep-4',
        type: 'episode',
        showId: 'show-1',
        hasFile: true,
      );

      expect(mediaContextActionsFor(target), isEmpty);
    });

    test('no target that navigates on tap is ever offered Play', () {
      for (final type in ['movie', 'tv_show', 'episode']) {
        final target = MediaContextTarget(
          id: 'x',
          type: type,
          showId: 'show-1',
          hasFile: true,
        );

        expect(
          mediaContextActionsFor(target),
          isEmpty,
          reason: '$type with tapPlays false must earn no menu',
        );
      }
    });

    test('every action has a label and an icon', () {
      for (final action in MediaContextAction.values) {
        expect(mediaContextLabel(action), isNotEmpty);
        expect(mediaContextIcon(action), isNotNull);
      }
    });
  });

  group('mediaContextActionsFor removal', () {
    test('a card with no dismissal target is offered no removal', () {
      const target = MediaContextTarget(
        id: 'mv-1',
        type: 'movie',
        hasFile: true,
        tapPlays: true,
      );

      expect(
        mediaContextActionsFor(target),
        isNot(contains(MediaContextAction.removeFromContinueWatching)),
      );
    });

    // The case the tapPlays early return used to swallow. The
    // `/continue-watching` grid opens the title on tap rather than playing it,
    // so every target it builds has tapPlays false — and it is the surface
    // where removal matters most.
    test('a card that navigates on tap is still offered removal', () {
      const target = MediaContextTarget(
        id: 'ep-1',
        type: 'episode',
        showId: 'show-1',
        hasFile: true,
        continueWatchingId: 'show-1',
      );

      expect(mediaContextActionsFor(target), [
        MediaContextAction.removeFromContinueWatching,
      ]);
    });

    test('removal comes last, after the navigation entries', () {
      const target = MediaContextTarget(
        id: 'ep-1',
        type: 'episode',
        showId: 'show-1',
        hasFile: true,
        tapPlays: true,
        continueWatchingId: 'show-1',
      );

      expect(mediaContextActionsFor(target), [
        MediaContextAction.play,
        MediaContextAction.goToShow,
        MediaContextAction.episodeDetails,
        MediaContextAction.removeFromContinueWatching,
      ]);
    });

    test('a movie card is offered removal keyed on itself', () {
      const target = MediaContextTarget(
        id: 'mv-1',
        type: 'movie',
        hasFile: true,
        tapPlays: true,
        continueWatchingId: 'mv-1',
      );

      expect(mediaContextActionsFor(target), [
        MediaContextAction.play,
        MediaContextAction.movieDetails,
        MediaContextAction.removeFromContinueWatching,
      ]);
    });
  });
}
