// Television-tier focus memory on the show detail page: the season selector
// and the episode rail each remember their place, and a season switch starts
// the episode rail over. Mounted in the real shell regions (`TvShell`), whose
// traversal policy carries `FocusMemory.requestFocus`.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/detail/source_detail_controllers.dart';
import 'package:player/presentation/screens/show/show_detail_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/tv_shell_harness.dart';
import '../detail/detail_harness.dart';
import '../sources/fake_media_source.dart';

const _show =
    ItemRef(sourceId: fakeSourceId, kind: ItemKind.show, externalId: 'sh-1');

ItemSummary _episode(int season, int number) => ItemSummary(
      ref: ItemRef(
        sourceId: fakeSourceId,
        kind: ItemKind.episode,
        externalId: 'ep-$season-$number',
      ),
      title: 'Episode $number',
      index: number,
      parentIndex: season,
      durationSeconds: 2580,
      defaultVersionId: 'file-$season-$number',
    );

Key _season(int n) => ValueKey('season-chip-$n');
Key _episodeCard(int season, int n) => ValueKey('ep-$season-$n');
Key _action(String id) => ValueKey('detail-action-$id');

/// Focus is on episode [n]'s card itself, not the watched menu in its
/// corner, which is a focus stop of its own inside the card.
void _expectOnEpisode(int season, int n) {
  expectFocusIn(_episodeCard(season, n));
  var inMenu = false;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
    inMenu = e.widget is PopupMenuButton;
    return !inMenu;
  });
  expect(inMenu, isFalse,
      reason: 'expected the card of episode $season-$n, '
          'but focus is on its watched menu');
}

void main() {
  group('show detail focus memory (TV)', () {
    Future<TvShell> pumpShow(WidgetTester tester) async {
      final source = ScriptedDetailSource(
        detailOf: (ref) => ref.kind == ItemKind.episode
            ? ItemDetail(
                summary: _episode(1, 1),
                versions: const [MediaVersion(id: 'v', height: 1080)],
              )
            : ItemDetail(
                summary: const ItemSummary(ref: _show, title: 'Invented Show'),
                cast: [for (var i = 0; i < 30; i++) Person(name: 'Actor $i')],
              ),
        childrenOf: (parent) => parent.kind == ItemKind.show
            ? [
                for (var s = 1; s <= 4; s++)
                  ItemSummary(
                    ref: ItemRef(
                      sourceId: fakeSourceId,
                      kind: ItemKind.season,
                      externalId: 'se-$s',
                    ),
                    title: 'Season $s',
                    index: s,
                  ),
              ]
            : [
                for (var n = 1; n <= 12; n++)
                  _episode(int.parse(parent.externalId.substring(3)), n),
              ],
      );
      final shell = TvShell();
      await mockNetworkImages(() => shell.pump(
            tester,
            const ShowDetailScreen.target(target: SourceTarget(_show)),
            overrides: [
              mediaSourceProvider(source.id).overrideWithValue(source),
              sourceArtworkProvider.overrideWith((ref, key) async => null),
              // No similar row, so its disclosure header is not a stop
              // between the hero bar and the seasons.
              sourceSimilarProvider(_show)
                  .overrideWith((_) => Stream.value(const <ItemSummary>[])),
            ],
          ));
      return shell;
    }

    testWidgets(
        'DOWN from the hero bar steps through the seasons, then the episodes, '
        'each entered on its first item', (tester) async {
      await pumpShow(tester);
      await focusIn(tester, _action('info'));

      // The cast rail between them has no focus stops, and the "Episodes"
      // heading's buttons sit at the far right, out of the way.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(_season(1));
      // Season 3 sits above the second episode card, which is where the
      // geometric search alone would land.
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expectFocusIn(_season(3));
      await press(tester, LogicalKeyboardKey.arrowDown);

      _expectOnEpisode(1, 1);
    });

    testWidgets('UP from the episodes returns to the season that left',
        (tester) async {
      await pumpShow(tester);
      await focusIn(tester, _season(3));

      await press(tester, LogicalKeyboardKey.arrowDown);
      _expectOnEpisode(1, 1);
      // A sideways move drops Flutter's own up/down history, so the return
      // below is the season selector's memory and not a replay.
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      _expectOnEpisode(1, 3);
      await press(tester, LogicalKeyboardKey.arrowUp);

      expectFocusIn(_season(3));
    });

    testWidgets('a new season is entered on its first episode', (tester) async {
      await pumpShow(tester);
      await focusIn(tester, _episodeCard(1, 1));
      for (var i = 0; i < 4; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      _expectOnEpisode(1, 5);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expectFocusIn(_season(1));
      await press(tester, LogicalKeyboardKey.arrowRight);
      expectFocusIn(_season(2));
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byKey(_episodeCard(2, 1)), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowDown);

      _expectOnEpisode(2, 1);
    });

    // Every season switch in the app passes through a loading frame today,
    // which rebuilds the episode rail on its own. Holding season 1's episodes
    // alive, as anything else watching them would, takes that frame away:
    // the rail is back with data at once, and only the per-season rail
    // keeps the old season's position from carrying over.
    testWidgets(
        'a season whose episodes are still loaded is entered on its first '
        'episode', (tester) async {
      final shell = await pumpShow(tester);
      final seasonOne = shell.container.listen(
        sourceSeasonProvider((show: _show, seasonNumber: 1)),
        (_, __) {},
      );
      addTearDown(seasonOne.close);
      await focusIn(tester, _season(2));
      await press(tester, LogicalKeyboardKey.enter);
      await focusIn(tester, _episodeCard(2, 1));
      for (var i = 0; i < 4; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      _expectOnEpisode(2, 5);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expectFocusIn(_season(2));
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expectFocusIn(_season(1));
      await press(tester, LogicalKeyboardKey.enter);
      await press(tester, LogicalKeyboardKey.arrowDown);

      _expectOnEpisode(1, 1);
    });
  }, skip: tvSkipReason);
}
