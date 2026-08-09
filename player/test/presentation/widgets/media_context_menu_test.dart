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

    test('every action has a label and an icon', () {
      for (final action in MediaContextAction.values) {
        expect(mediaContextLabel(action), isNotEmpty);
        expect(mediaContextIcon(action), isNotNull);
      }
    });
  });
}
