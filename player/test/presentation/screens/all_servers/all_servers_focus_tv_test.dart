// The All servers browse screens remember their place on a television: the
// merged poster grid and the chip bar above it each return focus to the item
// that last had it (the poster's ref, the chip's value), so moving between
// the bar and the grid never lands on "whatever is nearest".
//
// The real screens inside the shell's real content region (see
// `tv_shell_harness.dart`), at a Chromecast's 960x540 logical pixels.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/all_servers/all_servers_grid_screen.dart';
import 'package:player/presentation/screens/all_servers/all_servers_listing_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../domain/merged/fake_merged_source.dart';
import '../../../test_utils/tv_shell_harness.dart';

void main() {
  group('All servers focus memory (requires MYDIA_FORCE_TV=true)', () {
    final server = fakeServer('a');
    // Zero-padded so the title sort keeps them in number order.
    String id(int n) => 'f${n.toString().padLeft(2, '0')}';
    Key poster(int n) => ValueKey('all-poster-${server.id.value}-${id(n)}');
    const titleSort = Key('all-grid-sort-title');
    const releasedSort = Key('all-grid-sort-released');

    final source = FakeMergedSource(
      server,
      movies: [
        for (var n = 0; n < 40; n++)
          item(server, id(n),
              sortTitle: id(n), addedAt: DateTime.utc(2024, 1, 1 + n)),
      ],
      recent: [
        for (var n = 0; n < 40; n++)
          item(server, id(n), addedAt: DateTime.utc(2024, 3, 40 - n)),
      ],
    );

    List<Override> overrides() => [
          allServersSourcesProvider.overrideWithValue([source]),
          sourcesProvider.overrideWithValue([source.source]),
          mediaSourceProvider(source.id).overrideWithValue(source),
          allServersNeedSignInProvider.overrideWithValue(const []),
          sourceArtworkProvider.overrideWith((ref, key) async => null),
        ];

    Future<void> pumpGrid(WidgetTester tester) => TvShell().pump(
          tester,
          const AllServersGridScreen(kind: LibraryKind.movies),
          overrides: overrides(),
        );

    ScrollPosition gridPosition(WidgetTester tester) => tester
        .state<ScrollableState>(find
            .ancestor(
              of: find.byKey(poster(0), skipOffstage: false),
              matching: find.byType(Scrollable),
            )
            .first)
        .position;

    testWidgets('the grid entered for the first time lands on its first poster',
        (tester) async {
      await pumpGrid(tester);
      // The last chip, so the poster below it is not the first one.
      await focusIn(tester, releasedSort);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expectFocusIn(poster(0));
    });

    testWidgets('the sort bar is re-entered on the chip that left it',
        (tester) async {
      await pumpGrid(tester);
      await focusIn(tester, titleSort);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(poster(0));
      // Two over, not to the end of the row: at 960 logical pixels the last
      // poster of the first row sits under the title row's cast button, and
      // UP from there enters the title row, which overlaps it, rather than
      // the chip bar, which does not. Which row UP enters is the geometric
      // search's choice; what is under test is where in the bar it lands.
      for (var i = 0; i < 2; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expectFocusIn(poster(2));

      await press(tester, LogicalKeyboardKey.arrowUp);

      expectFocusIn(titleSort);
    });

    testWidgets(
        'UP then DOWN returns to the poster that left, with the grid scrolled',
        (tester) async {
      await pumpGrid(tester);
      await focusIn(tester, titleSort);
      await press(tester, LogicalKeyboardKey.arrowDown);
      for (var i = 0; i < 2; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expectFocusIn(poster(2));
      await press(tester, LogicalKeyboardKey.arrowUp);
      expectFocusIn(titleSort);
      // Leave the chip the viewer arrived on, so the next DOWN is not a
      // replay of Flutter's own up/down history.
      await press(tester, LogicalKeyboardKey.arrowRight);

      final grid = gridPosition(tester);
      grid.jumpTo(grid.pixels + 150);
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(poster(2));
    });

    testWidgets('Recently added: the kind bar is re-entered on its chip',
        (tester) async {
      await TvShell().pump(
        tester,
        const AllServersListingScreen(listing: AllServersListing.recentlyAdded),
        overrides: overrides(),
      );
      await focusIn(tester, const Key('all-listing-kind-all'));
      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(poster(0));
      for (var i = 0; i < 2; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expectFocusIn(poster(2));

      await press(tester, LogicalKeyboardKey.arrowUp);

      expectFocusIn(const Key('all-listing-kind-all'));
    });
  }, skip: tvSkipReason);
}
