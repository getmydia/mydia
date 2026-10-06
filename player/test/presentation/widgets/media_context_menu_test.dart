// The long-press menu's visibility rules, asserted as pure logic.
//
// mediaContextActionsFor is deliberately a plain function rather than a widget
// concern: what a card's menu offers depends only on the target, so the rules
// are tested without pumping a menu, and showMediaContextMenu is left with
// nothing but presentation and routing.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/widgets/media_context_menu.dart';

const _source = SourceId('a:b:c');

ItemRef _ref(ItemKind kind, String id) =>
    ItemRef(sourceId: _source, kind: kind, externalId: id);

final _show = _ref(ItemKind.show, 'show-1');

void main() {
  group('mediaContextActionsFor', () {
    test('an Up Next episode offers play, its show, and its own details', () {
      final target = MediaContextTarget(
        item: _ref(ItemKind.episode, 'ep-1'),
        show: _show,
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
      final target = MediaContextTarget(
        item: _ref(ItemKind.movie, 'mv-1'),
        hasFile: true,
        tapPlays: true,
      );

      expect(mediaContextActionsFor(target), [
        MediaContextAction.play,
        MediaContextAction.movieDetails,
      ]);
    });

    test('a target with no playable file offers no play', () {
      final target = MediaContextTarget(
        item: _ref(ItemKind.episode, 'ep-2'),
        show: _show,
        tapPlays: true,
      );

      expect(
        mediaContextActionsFor(target),
        isNot(contains(MediaContextAction.play)),
      );
    });

    test('an episode with no known show omits Go to show', () {
      final target = MediaContextTarget(
        item: _ref(ItemKind.episode, 'ep-3'),
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
      final target = MediaContextTarget(item: _ref(ItemKind.movie, 'mv-2'));

      expect(mediaContextActionsFor(target), isEmpty);
    });

    // Regression for the two holes left by gating only movieDetails on
    // tapPlays. A playable episode on a rail with no play handler used to be
    // offered Play, which routes through a nullable onItemActivate and would
    // have done nothing, plus an Episode details entry duplicating its own tap.
    test('a playable episode whose tap navigates earns an empty menu', () {
      final target = MediaContextTarget(
        item: _ref(ItemKind.episode, 'ep-4'),
        show: _show,
        hasFile: true,
      );

      expect(mediaContextActionsFor(target), isEmpty);
    });

    test('no target that navigates on tap is ever offered Play', () {
      for (final kind in [ItemKind.movie, ItemKind.show, ItemKind.episode]) {
        final target = MediaContextTarget(
          item: _ref(kind, 'x'),
          show: _show,
          hasFile: true,
        );

        expect(
          mediaContextActionsFor(target),
          isEmpty,
          reason: '${kind.name} with tapPlays false must earn no menu',
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
      final target = MediaContextTarget(
        item: _ref(ItemKind.movie, 'mv-1'),
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
    // so every target it builds has tapPlays false, and it is the surface
    // where removal matters most.
    test('a card that navigates on tap is still offered removal', () {
      final target = MediaContextTarget(
        item: _ref(ItemKind.episode, 'ep-1'),
        show: _show,
        hasFile: true,
        continueWatching: _show,
      );

      expect(mediaContextActionsFor(target), [
        MediaContextAction.removeFromContinueWatching,
      ]);
    });

    test('removal comes last, after the navigation entries', () {
      final target = MediaContextTarget(
        item: _ref(ItemKind.episode, 'ep-1'),
        show: _show,
        hasFile: true,
        tapPlays: true,
        continueWatching: _show,
      );

      expect(mediaContextActionsFor(target), [
        MediaContextAction.play,
        MediaContextAction.goToShow,
        MediaContextAction.episodeDetails,
        MediaContextAction.removeFromContinueWatching,
      ]);
    });

    test('a movie card is offered removal keyed on itself', () {
      final movie = _ref(ItemKind.movie, 'mv-1');
      final target = MediaContextTarget(
        item: movie,
        hasFile: true,
        tapPlays: true,
        continueWatching: movie,
      );

      expect(mediaContextActionsFor(target), [
        MediaContextAction.play,
        MediaContextAction.movieDetails,
        MediaContextAction.removeFromContinueWatching,
      ]);
    });
  });
}
