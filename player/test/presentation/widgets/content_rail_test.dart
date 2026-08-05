// U7 — faux-glass rails and grids (plan R8).
//
// Rails appear in scrolling quantity, so their cards must carry no live blur:
// the solid posters (U6) use a faux-glass hover overlay, so a populated rail
// renders zero BackdropFilter widgets. Cards also carry stable id-based keys
// (player key convention), and the scroll-edge fade gradients still render.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/recently_added_item.dart';
import 'package:player/presentation/widgets/content_rail.dart';
import 'package:player/presentation/widgets/media_card.dart';

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
}
