// Directional traversal can only reach widgets that have been built, and a
// ListView.builder / GridView.builder builds only what is visible plus
// cacheExtent. Without a raised cacheExtent, a D-pad viewer moving along a
// rail or down the library grid hits an invisible wall at the viewport edge:
// there is no next widget to focus, so nothing happens and the list never
// scrolls.
//
// These tests pump the real product widgets (ContentRail, HorizontalRail,
// BrowseGrid) and read `.scrollCacheExtent` off the ListView/GridView each
// one actually builds (this Flutter SDK deprecated the plain double
// `cacheExtent` in favour of `scrollCacheExtent: ScrollCacheExtent`, so the
// product code passes the new one), so a regression that removed the gate
// from the real build method fails here. A local ListView stand-in would
// pass unconditionally, since Flutter's ListView.builder always honours
// whatever cache extent it is given; it is the product code's gating on
// InputCapabilities.directionalPrimary that these tests are checking, not
// ListView itself.
//
// `InputCapabilities.directionalPrimary` is derived in part from
// `MYDIA_FORCE_TV`, a compile-time flag (`bool.fromEnvironment`), so it
// cannot be flipped at runtime from inside a single test file: every test in
// one process sees the same value. These tests read that real, live value
// and assert whichever branch is actually in effect, so the file is honest
// under both invocations:
//   ./dev flutter test --concurrency=1 test/presentation/widgets/rail_traversal_test.dart
//     -> directionalPrimary is false; the "not gated" branch runs, the
//        directional-only traversal group is skipped.
//   ./dev flutter test --concurrency=1 --dart-define=MYDIA_FORCE_TV=true test/presentation/widgets/rail_traversal_test.dart
//     -> directionalPrimary is true; the "gated" branch runs, and the
//        traversal group actually walks focus off the built viewport and
//        checks the rail scrolled.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/domain/models/recently_added_item.dart';
import 'package:player/presentation/widgets/browse_grid.dart';
import 'package:player/presentation/widgets/content_rail.dart';
import 'package:player/presentation/widgets/horizontal_rail.dart';
import 'package:player/presentation/widgets/media_card.dart';

Widget _host(Widget child) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: child),
      ),
    );

List<RecentlyAddedItem> _items(int n) => List.generate(
      n,
      (i) => RecentlyAddedItem(id: '$i', type: 'movie', title: 'Title $i'),
    );

void main() {
  // Captured once: this is a compile-time constant for the whole process, so
  // every test below sees the same answer.
  final directional = InputCapabilities.directionalPrimary;

  group('ContentRail cacheExtent gating (product code)', () {
    testWidgets(
        'the ListView ContentRail actually builds carries the gated cacheExtent',
        (tester) async {
      await tester.pumpWidget(
        _host(ContentRail(title: 'Recently Added', items: _items(20))),
      );
      await tester.pump();

      final list = tester.widget<ListView>(find.byType(ListView));
      if (directional) {
        expect(list.scrollCacheExtent, isNotNull);
      } else {
        expect(list.scrollCacheExtent, isNull);
      }
    });
  });

  group('HorizontalRail cacheExtent gating (product code)', () {
    // EpisodeRail and DownloadedEpisodeRail both delegate their scrolling
    // list to HorizontalRail rather than building their own ListView, so
    // this is the one place the gate needs to live for either to inherit it.
    testWidgets(
        'the ListView HorizontalRail actually builds carries the gated cacheExtent',
        (tester) async {
      await tester.pumpWidget(
        _host(HorizontalRail(
          itemCount: 20,
          height: 200,
          leftFadeKey: const ValueKey('rail-traversal-left-fade'),
          rightFadeKey: const ValueKey('rail-traversal-right-fade'),
          itemBuilder: (context, index) => SizedBox(
            key: ValueKey('rail-traversal-item-$index'),
            width: 150,
            child: Text('Item $index'),
          ),
        )),
      );
      await tester.pump();

      final list = tester.widget<ListView>(find.byType(ListView));
      if (directional) {
        expect(list.scrollCacheExtent, isNotNull);
      } else {
        expect(list.scrollCacheExtent, isNull);
      }
    });
  });

  group('BrowseGrid cacheExtent gating (product code)', () {
    testWidgets(
        'the GridView BrowseGrid actually builds carries the gated cacheExtent',
        (tester) async {
      await tester.pumpWidget(
        _host(BrowseGrid(
          itemCount: 40,
          scrollTopPadding: 100,
          itemBuilder: (context, index) => SizedBox(
            key: ValueKey('grid-traversal-item-$index'),
            child: Text('Item $index'),
          ),
        )),
      );
      await tester.pump();

      final grid = tester.widget<GridView>(find.byType(GridView));
      if (directional) {
        expect(grid.scrollCacheExtent, isNotNull);
      } else {
        expect(grid.scrollCacheExtent, isNull);
      }
    });
  });

  group(
    'ContentRail directional traversal (product code, directional tier only)',
    () {
      setUp(() {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
      });

      tearDown(() {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic;
      });

      testWidgets(
          'focus walks past the viewport edge and scrolls the real rail with it',
          (tester) async {
        tester.view.physicalSize = const Size(800, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _host(ContentRail(title: 'Recently Added', items: _items(40))),
        );
        await tester.pump();

        final scope =
            FocusScope.of(tester.element(find.byType(MediaCard).first));

        // 800px viewport at roughly 146px per card holds about 5 cards.
        // Walking 12 stops takes focus well past the edge and forces the
        // list to scroll, which only works if enough cards past the edge
        // were actually built.
        for (var i = 0; i < 12; i++) {
          scope.nextFocus();
          await tester.pump();
        }

        expect(scope.focusedChild, isNotNull);

        final position = tester
            .stateList<ScrollableState>(find.byType(Scrollable))
            .map((s) => s.position)
            .firstWhere((p) => p.axis == Axis.horizontal);
        expect(
          position.pixels,
          greaterThan(0),
          reason:
              'focus moving past the viewport edge must have scrolled the rail',
        );
      });
    },
    skip: directional
        ? false
        : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
            'InputCapabilities.directionalPrimary; forcedTv is a compile-time '
            'flag (bool.fromEnvironment) and cannot be toggled at test '
            'runtime, so this group only exercises anything when the whole '
            'test process is compiled with that define.',
  );
}
