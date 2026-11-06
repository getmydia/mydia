// Home's rows remember their place on a television: entering a row lands on
// the card that last had focus there (its first card on a first visit), a
// reordered Continue Watching still returns to the same title, and none of it
// is lost while a detail page sits over Home.
//
// The real HomeScreen inside the shell's real content region (see
// `tv_shell_harness.dart`), at 1920x1080. On Home a titled row's heading is
// itself a focus stop (it opens the full listing), so a vertical move from a
// card reaches the next row's heading first and the row itself one press
// later. The heading spans the screen's width, so what the geometric search
// alone picks below or above it is a card near the middle of the screen,
// never the remembered one these cases expect.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/home/home_scope.dart';
import 'package:player/presentation/screens/home/home_screen.dart';
import 'package:player/presentation/screens/sources/source_browse_providers.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../domain/merged/fake_merged_source.dart';
import '../../../test_utils/tv_shell_harness.dart';

void main() {
  group('Home focus memory (requires MYDIA_FORCE_TV=true)', () {
    final server = fakeServer('a');

    ItemSummary resumingItem(int n, {int day = 0}) => item(server, 'cw$n',
        durationSeconds: 3600,
        progress: 600,
        lastPlayedAt: DateTime.utc(2024, 1, 20 - n + day));

    Key cw(int n) => ValueKey('home-continue-${server.id.value}-cw$n');
    Key movie(int n) => ValueKey('source-poster-mv$n');
    const recentMovies = Key('home-recent-movies');
    const continueWatching = Key('home-continue-watching');
    const heroPlay = Key('source-home-hero-play');
    const heroMore = Key('source-home-hero-more');

    late List<ItemSummary> resuming;
    late TvShell shell;

    Future<void> pumpHome(WidgetTester tester) async {
      // Mutable on purpose: the reorder case edits it and refetches.
      resuming = [for (var n = 0; n < 8; n++) resumingItem(n)];
      final source = FakeMergedSource(
        server,
        resuming: resuming,
        recent: [
          for (var n = 0; n < 16; n++)
            item(server, 'mv$n', addedAt: DateTime.utc(2024, 1, 20 - n)),
        ],
      );
      shell = TvShell();
      await shell.pump(
        tester,
        const HomeScreen(scope: AllServers()),
        overrides: [
          allServersSourcesProvider.overrideWithValue([source]),
          sourcesProvider.overrideWithValue([source.source]),
          mediaSourceProvider(source.id).overrideWithValue(source),
          allServersNeedSignInProvider.overrideWithValue(const []),
          // No artwork requests: a poster with a URL spins until the blocked
          // test HTTP client answers, which pumpAndSettle never outlasts.
          sourceArtworkProvider.overrideWith((ref, key) async => null),
        ],
      );
    }

    /// The row keyed [row]'s heading has focus: the first focus stop in it.
    void expectOnHeading(WidgetTester tester, Key row) => expect(
        nodeIn(tester, row).hasPrimaryFocus, isTrue,
        reason: 'expected the heading of $row, focus is on ${describeFocus()}');

    ScrollPosition railPosition(WidgetTester tester, Key row) => tester
        .state<ScrollableState>(find.descendant(
          of: find.byKey(row),
          matching: find.byType(Scrollable),
        ))
        .position;

    /// From cw[n] down to Recent movies' cards: the heading, then the row.
    Future<void> downIntoMovies(WidgetTester tester) async {
      await press(tester, LogicalKeyboardKey.arrowDown);
      expectOnHeading(tester, recentMovies);
      await press(tester, LogicalKeyboardKey.arrowDown);
    }

    /// From a Recent movies card up to Continue Watching's cards.
    Future<void> upIntoContinueWatching(WidgetTester tester) async {
      await press(tester, LogicalKeyboardKey.arrowUp);
      expectOnHeading(tester, recentMovies);
      await press(tester, LogicalKeyboardKey.arrowUp);
    }

    // Ported from home_screen_test.dart, where it never ran in CI. The row
    // heading is a focus stop of its own, so UP from the first card reaches
    // Continue Watching's heading first and the hero one press later.
    testWidgets('UP from the first rail card reaches the hero Play button',
        (tester) async {
      await pumpHome(tester);
      await focusIn(tester, cw(0));

      await press(tester, LogicalKeyboardKey.arrowUp);
      expectOnHeading(tester, continueWatching);
      // The heading spans the screen, so the geometric search alone picks the
      // hero button nearer its centre (More). The hero's button bar sends a
      // first entry to Play.
      await press(tester, LogicalKeyboardKey.arrowUp);

      expectFocusIn(heroPlay);
    });

    testWidgets('the hero buttons are re-entered on the one that left',
        (tester) async {
      await pumpHome(tester);
      await focusIn(tester, heroMore);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expectOnHeading(tester, continueWatching);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(cw(0));
      // A sideways move clears Flutter's own up/down history.
      await press(tester, LogicalKeyboardKey.arrowRight);
      expectFocusIn(cw(1));

      await press(tester, LogicalKeyboardKey.arrowUp);
      expectOnHeading(tester, continueWatching);
      await press(tester, LogicalKeyboardKey.arrowUp);

      expectFocusIn(heroMore);
    });

    testWidgets('a row entered for the first time lands on its first card',
        (tester) async {
      await pumpHome(tester);
      await focusIn(tester, cw(3));

      await downIntoMovies(tester);

      expectFocusIn(movie(0));
    });

    testWidgets(
        'DOWN then UP returns to the card that left, with its row scrolled',
        (tester) async {
      await pumpHome(tester);
      await focusIn(tester, cw(5));
      await downIntoMovies(tester);
      expectFocusIn(movie(0));
      // Over and back, so the UP below is not a replay of Flutter's own
      // up/down history.
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expectFocusIn(movie(0));

      // Shift Continue Watching under the viewer, keeping cw5 built.
      railPosition(tester, continueWatching).jumpTo(200);
      await tester.pumpAndSettle();

      await upIntoContinueWatching(tester);
      expectFocusIn(cw(5));
    });

    testWidgets('a visited row is re-entered on its remembered card',
        (tester) async {
      await pumpHome(tester);
      await focusIn(tester, cw(5));
      await downIntoMovies(tester);
      for (var i = 0; i < 9; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expectFocusIn(movie(9));

      // Sideways moves clear Flutter's own up/down history, so the landings
      // below are the rows' memory, not a replay of an earlier press.
      await upIntoContinueWatching(tester);
      expectFocusIn(cw(5));
      await press(tester, LogicalKeyboardKey.arrowRight);
      expectFocusIn(cw(6));

      await downIntoMovies(tester);
      expectFocusIn(movie(9));
    });

    testWidgets("LEFT from a row's first card reaches the rail, RIGHT returns",
        (tester) async {
      await pumpHome(tester);
      await focusIn(tester, cw(3));
      await downIntoMovies(tester);
      expectFocusIn(movie(0));

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(shell.sidebarRow.hasPrimaryFocus, isTrue,
          reason: 'focus is on ${describeFocus()}');

      await press(tester, LogicalKeyboardKey.arrowRight);
      expectFocusIn(movie(0));
    });

    testWidgets(
        'Continue Watching moving the remembered title to the front still '
        'returns to that title', (tester) async {
      await pumpHome(tester);
      await focusIn(tester, cw(5));
      await downIntoMovies(tester);
      expectFocusIn(movie(0));

      // cw5 is played again elsewhere: it is now the most recent.
      resuming
        ..removeAt(5)
        ..insert(0, resumingItem(5, day: 10));
      shell.container.invalidate(sourceContinueWatchingProvider(server.id));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(cw(5), skipOffstage: false)).dx,
        lessThan(tester.getTopLeft(find.byKey(cw(0), skipOffstage: false)).dx),
        reason: 'the refetch put cw5 first',
      );

      // The slot cw5 used to hold (index 5) now holds cw4: only the title's
      // identity leads back to cw5, now at the front.
      await press(tester, LogicalKeyboardKey.arrowRight);
      expectFocusIn(movie(1));
      await upIntoContinueWatching(tester);
      expectFocusIn(cw(5));
    });

    testWidgets('rows keep their memory under a detail page and after it pops',
        (tester) async {
      await pumpHome(tester);
      await focusIn(tester, cw(5));
      await downIntoMovies(tester);
      for (var i = 0; i < 9; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expectFocusIn(movie(9));

      // Completes only when the page pops, which this test does itself.
      unawaited(shell.router.push('/s/${server.id.value}/movie/mv9'));
      await tester.pumpAndSettle();
      expectFocusIn(tvDetailStandInKey);
      // Home stays mounted under the detail page, as in the app's shell.
      expect(find.byType(HomeScreen, skipOffstage: false), findsOneWidget);

      shell.router.pop();
      await tester.pumpAndSettle();
      expectFocusIn(movie(9));

      await upIntoContinueWatching(tester);
      expectFocusIn(cw(5));
      await press(tester, LogicalKeyboardKey.arrowRight);
      expectFocusIn(cw(6));
      await downIntoMovies(tester);
      expectFocusIn(movie(9));
    });
  }, skip: tvSkipReason);
}
