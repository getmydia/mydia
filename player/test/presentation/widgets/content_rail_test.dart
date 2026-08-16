// U7 — faux-glass rails and grids (plan R8).
//
// Rails appear in scrolling quantity, so their cards must carry no live blur:
// the solid posters (U6) respond to hover with a shadow deepening alone, so a
// populated rail renders zero BackdropFilter widgets. Cards also carry stable
// id-based keys (player key convention), and the scroll-edge fade gradients
// still render.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/continue_watching_item.dart';
import 'package:player/domain/models/media_file.dart';
import 'package:player/domain/models/progress.dart';
import 'package:player/domain/models/recently_added_item.dart';
import 'package:player/domain/models/up_next_item.dart';
import 'package:player/domain/models/watch_status.dart';
import 'package:player/presentation/widgets/content_rail.dart';
import 'package:player/presentation/widgets/media_card.dart';
import 'package:player/presentation/widgets/media_context_menu.dart';
import 'package:player/presentation/widgets/progress_overlay.dart';
import 'package:player/presentation/widgets/watch_indicator.dart';

List<RecentlyAddedItem> _items(int n) => List.generate(
      n,
      (i) => RecentlyAddedItem(id: '$i', type: 'movie', title: 'Title $i'),
    );

Widget _host(Widget child) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: child),
      ),
    );

void main() {
  group('ContentRail (R8)', () {
    testWidgets('a populated rail renders no live blur in its cards',
        (tester) async {
      await tester.pumpWidget(
        _host(ContentRail(title: 'Recently Added', items: _items(5))),
      );
      await tester.pump();

      expect(find.byType(MediaCard), findsWidgets);
      // R8: zero per-card BackdropFilter passes in the scrolling rail.
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('rail cards carry stable id-based keys', (tester) async {
      await tester.pumpWidget(
        _host(ContentRail(title: 'Recently Added', items: _items(3))),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('ra-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('ra-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('ra-2')), findsOneWidget);
    });

    testWidgets('renders the right-edge fade gradient initially',
        (tester) async {
      await tester.pumpWidget(
        _host(ContentRail(title: 'Recently Added', items: _items(20))),
      );
      await tester.pump();

      // The fade gradients are IgnorePointer-wrapped gradient containers; at
      // rest (scrolled to start) the right fade is shown.
      expect(find.byType(IgnorePointer), findsWidgets);
    });

    testWidgets('an empty rail collapses to nothing', (tester) async {
      await tester.pumpWidget(
        _host(const ContentRail(title: 'Recently Added', items: [])),
      );
      await tester.pump();

      expect(find.byType(MediaCard), findsNothing);
    });
  });

  // The show detail screen's "Similar in your library" rail is supporting
  // context, so it opens closed and the posters are never built until asked
  // for. Every other rail on every other surface must be untouched by that.
  group('ContentRail disclosure', () {
    testWidgets('a collapsible rail starts closed, showing only its header',
        (tester) async {
      await tester.pumpWidget(
        _host(ContentRail(
          title: 'Similar in your library',
          items: _items(5),
          collapsible: true,
        )),
      );
      await tester.pumpAndSettle();

      expect(find.text('Similar in your library'), findsOneWidget);
      expect(find.byKey(ContentRail.disclosureKey), findsOneWidget);
      expect(find.byType(MediaCard), findsNothing);
    });

    testWidgets('tapping the header opens the rail and tapping again closes it',
        (tester) async {
      await tester.pumpWidget(
        _host(ContentRail(
          title: 'Similar in your library',
          items: _items(5),
          collapsible: true,
        )),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Similar in your library'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaCard), findsWidgets);

      await tester.tap(find.text('Similar in your library'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaCard), findsNothing);
    });

    testWidgets('a rail is open with no chevron unless asked to collapse',
        (tester) async {
      await tester.pumpWidget(
        _host(ContentRail(title: 'Recently Added', items: _items(5))),
      );
      await tester.pumpAndSettle();

      expect(find.byType(MediaCard), findsWidgets);
      expect(find.byKey(ContentRail.disclosureKey), findsNothing);
    });
  });

  group('ContentRail RecentlyAddedItem subtitle', () {
    // Regression guard for `item.newContentLabel ?? item.year?.toString()`:
    // if that coalescing order is ever flipped, this is the test that catches
    // it, since the item carries both a year and episode context.
    testWidgets(
        'a show with one new episode shows the episode code, not the year',
        (tester) async {
      const item = RecentlyAddedItem(
        id: 'show-1',
        type: 'tv_show',
        title: 'The Bear',
        year: 2023,
        newEpisodeCount: 1,
        latestSeasonNumber: 4,
        latestEpisodeNumber: 2,
      );

      await tester.pumpWidget(
        _host(const ContentRail(title: 'Recently Added', items: [item])),
      );
      await tester.pump();

      expect(find.text('S04E02'), findsOneWidget);
      expect(find.text('2023'), findsNothing);
    });

    testWidgets('a movie with no episode context falls back to the year',
        (tester) async {
      const item = RecentlyAddedItem(
        id: 'movie-1',
        type: 'movie',
        title: 'A Movie',
        year: 2023,
      );

      await tester.pumpWidget(
        _host(const ContentRail(title: 'Recently Added', items: [item])),
      );
      await tester.pump();

      expect(find.text('2023'), findsOneWidget);
    });
  });

  // The regression guard for the reported bug: two of these four rails start
  // playback on tap and two open the title, and before MediaCardAction the
  // widget could not tell which it was doing.
  group('ContentRail card actions', () {
    const file = MediaFile(id: 'file-1', directPlaySupported: true);

    const continueWatching = ContinueWatchingItem(
      id: 'cw-1',
      type: 'movie',
      title: 'In Progress',
      files: [file],
    );

    const upNext = UpNextItem(
      progressState: 'next_up',
      episode: UpNextEpisode(
        id: 'ep-1',
        seasonNumber: 1,
        episodeNumber: 2,
        title: 'Pilot',
        hasFile: true,
        files: [file],
      ),
      show: UpNextShow(id: 'show-1', title: 'The Bear'),
    );

    MediaCardAction actionOf(WidgetTester tester) =>
        tester.widget<MediaCard>(find.byType(MediaCard)).action;

    testWidgets('the Continue Watching rail promises playback', (tester) async {
      await tester.pumpWidget(
        _host(ContentRail(
          title: 'Continue Watching',
          items: const [continueWatching],
          onItemActivate: (_) {},
        )),
      );
      await tester.pump();

      expect(actionOf(tester), MediaCardAction.play);
    });

    testWidgets('the Up Next rail promises playback', (tester) async {
      await tester.pumpWidget(
        _host(ContentRail(
          title: 'Up Next',
          items: const [upNext],
          onItemActivate: (_) {},
        )),
      );
      await tester.pump();

      expect(actionOf(tester), MediaCardAction.play);
    });

    testWidgets('the Recently Added rail promises navigation', (tester) async {
      await tester.pumpWidget(
        _host(ContentRail(title: 'Recently Added', items: _items(1))),
      );
      await tester.pump();

      expect(actionOf(tester), MediaCardAction.open);
    });

    // A rail card with nothing playable behind it must not promise playback:
    // home_screen.dart:128 falls back to the detail screen for exactly this
    // case, so the badge would be advertising a tap that navigates.
    testWidgets('an unplayable Continue Watching card promises navigation',
        (tester) async {
      await tester.pumpWidget(
        _host(ContentRail(
          title: 'Continue Watching',
          items: const [
            ContinueWatchingItem(id: 'cw-2', type: 'movie', title: 'No Files'),
          ],
          onItemActivate: (_) {},
        )),
      );
      await tester.pump();

      expect(actionOf(tester), MediaCardAction.open);
    });
  });

  group('ContentRail context menu', () {
    testWidgets('long-pressing an Up Next card offers its show and details',
        (tester) async {
      const upNext = UpNextItem(
        progressState: 'next_up',
        episode: UpNextEpisode(
          id: 'ep-1',
          seasonNumber: 1,
          episodeNumber: 2,
          title: 'Pilot',
          hasFile: true,
        ),
        show: UpNextShow(id: 'show-1', title: 'The Bear'),
      );

      await tester.pumpWidget(
        _host(ContentRail(
          title: 'Up Next',
          items: const [upNext],
          onItemActivate: (_) {},
        )),
      );
      await tester.pump();

      await tester.longPress(find.byType(MediaCard));
      await tester.pumpAndSettle();

      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Go to show'), findsOneWidget);
      expect(find.text('Episode details'), findsOneWidget);
    });

    // The rails that already open the title on tap earn nothing from a menu
    // offering to open the title, so they get none.
    testWidgets('long-pressing a Recently Added card opens no menu',
        (tester) async {
      await tester.pumpWidget(
        _host(ContentRail(title: 'Recently Added', items: _items(1))),
      );
      await tester.pump();

      await tester.longPress(find.byType(MediaCard));
      await tester.pumpAndSettle();

      expect(find.byType(PopupMenuItem<MediaContextAction>), findsNothing);
    });
  });

  group('ContentRail watch indicators', () {
    testWidgets('draws an unwatched dot on a recently added movie',
        (tester) async {
      const item = RecentlyAddedItem(
        id: 'ra-1',
        type: 'movie',
        title: 'Fresh Movie',
        watchStatus: WatchStatus(watched: false),
      );

      await tester.pumpWidget(
        _host(const ContentRail(title: 'Recently Added', items: [item])),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(WatchIndicator.dotKey), findsOneWidget);
    });

    testWidgets('draws an unwatched count on a recently added show',
        (tester) async {
      const item = RecentlyAddedItem(
        id: 'ra-2',
        type: 'tv_show',
        title: 'Fresh Show',
        watchStatus: WatchStatus(watched: false, unwatchedEpisodeCount: 4),
      );

      await tester.pumpWidget(
        _host(const ContentRail(title: 'Recently Added', items: [item])),
      );
      await tester.pumpAndSettle();

      expect(find.text('4'), findsOneWidget);
    });

    testWidgets('draws no bar for a watched continue-watching item',
        (tester) async {
      // The rail carried the legacy `progressPercentage` and no status, so a
      // finished item drew a full bar here while every other surface drew
      // nothing.
      const item = ContinueWatchingItem(
        id: 'cw-2',
        type: 'movie',
        title: 'Finished',
        progress: Progress(
          positionSeconds: 100,
          durationSeconds: 100,
          percentage: 100,
          watched: true,
        ),
      );

      await tester.pumpWidget(
        _host(const ContentRail(title: 'Continue Watching', items: [item])),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ProgressOverlay), findsNothing);
    });
  });
}
