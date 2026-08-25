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
// This file covers the non-directional (default) tier only: phone, desktop
// and web all see InputCapabilities.directionalPrimary == false, which is
// what every plain `flutter test` run exercises, so the gate must resolve to
// a null cacheExtent here. The directional tier lives in the sibling
// rail_traversal_tv_test.dart. It is named `*_tv_test.dart` on purpose,
// mirroring the existing `*_web_test.dart` convention for browser-only
// tests, so CI's dedicated television-tier step (which compiles with
// --dart-define=MYDIA_FORCE_TV=true) can find it by pattern instead of
// someone remembering to add it to a list.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/recently_added_item.dart';
import 'package:player/presentation/widgets/browse_grid.dart';
import 'package:player/presentation/widgets/content_rail.dart';
import 'package:player/presentation/widgets/horizontal_rail.dart';

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
  group('ContentRail cacheExtent gating (product code)', () {
    testWidgets(
        'the ListView ContentRail actually builds carries no cacheExtent '
        'outside the directional tier', (tester) async {
      await tester.pumpWidget(
        _host(ContentRail(title: 'Recently Added', items: _items(20))),
      );
      await tester.pump();

      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.scrollCacheExtent, isNull);
    });
  });

  group('HorizontalRail cacheExtent gating (product code)', () {
    // EpisodeRail and DownloadedEpisodeRail both delegate their scrolling
    // list to HorizontalRail rather than building their own ListView, so
    // this is the one place the gate needs to live for either to inherit it.
    testWidgets(
        'the ListView HorizontalRail actually builds carries no cacheExtent '
        'outside the directional tier', (tester) async {
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
      expect(list.scrollCacheExtent, isNull);
    });
  });

  group('BrowseGrid cacheExtent gating (product code)', () {
    testWidgets(
        'the GridView BrowseGrid actually builds carries no cacheExtent '
        'outside the directional tier', (tester) async {
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
      expect(grid.scrollCacheExtent, isNull);
    });
  });
}
