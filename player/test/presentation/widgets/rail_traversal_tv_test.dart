// The directional tier of rail_traversal_test.dart: proof that
// InputCapabilities.directionalPrimary == true actually raises the cache
// margin on ContentRail, HorizontalRail and BrowseGrid, and that the raised
// margin is enough for real D-pad focus traversal to walk a rail past its
// initially built viewport and scroll it with it.
//
// InputCapabilities.directionalPrimary is compile-time influenced
// (MYDIA_FORCE_TV, a bool.fromEnvironment flag), so a plain `flutter test`
// run never sees it as true: every test in this file needs the whole
// process compiled with --dart-define=MYDIA_FORCE_TV=true. Without that,
// this file's tests skip themselves rather than fail, so it stays green
// when a whole-suite run sweeps it up without the define (the "Run tests"
// CI step does exactly that). The assertions only actually run under the
// dedicated "Run television-tier tests" CI step, which enumerates
// test/**/*_tv_test.dart and runs that list with the define. That naming
// convention, mirroring the existing *_web_test.dart one for browser tests,
// is what makes this file, and any later directional-tier test file, picked
// up automatically rather than relying on someone editing a list by hand.

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
  final skipReason = InputCapabilities.directionalPrimary
      ? false
      : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
          'InputCapabilities.directionalPrimary; forcedTv is a compile-time '
          'flag (bool.fromEnvironment), so this file is a deliberate no-op '
          'unless the whole test process is compiled with that define. CI '
          'runs it explicitly in the "Run television-tier tests" step.';

  group('Directional tier (requires MYDIA_FORCE_TV=true)', () {
    testWidgets(
        'ContentRail carries the gated cacheExtent in the directional tier',
        (tester) async {
      await tester.pumpWidget(
        _host(ContentRail(title: 'Recently Added', items: _items(20))),
      );
      await tester.pump();

      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.scrollCacheExtent, isNotNull);
    });

    testWidgets(
        'HorizontalRail carries the gated cacheExtent in the directional '
        'tier', (tester) async {
      await tester.pumpWidget(
        _host(HorizontalRail(
          itemCount: 20,
          height: 200,
          leftFadeKey: const ValueKey('rail-traversal-tv-left-fade'),
          rightFadeKey: const ValueKey('rail-traversal-tv-right-fade'),
          itemBuilder: (context, index) => SizedBox(
            key: ValueKey('rail-traversal-tv-item-$index'),
            width: 150,
            child: Text('Item $index'),
          ),
        )),
      );
      await tester.pump();

      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.scrollCacheExtent, isNotNull);
    });

    testWidgets(
        'BrowseGrid carries the gated cacheExtent in the directional tier',
        (tester) async {
      await tester.pumpWidget(
        _host(BrowseGrid(
          itemCount: 40,
          scrollTopPadding: 100,
          itemBuilder: (context, index) => SizedBox(
            key: ValueKey('grid-traversal-tv-item-$index'),
            child: Text('Item $index'),
          ),
        )),
      );
      await tester.pump();

      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(grid.scrollCacheExtent, isNotNull);
    });

    group('ContentRail directional traversal', () {
      setUp(() {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
      });

      tearDown(() {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic;
      });

      testWidgets(
          'focus walks past the viewport edge and scrolls the real rail '
          'with it', (tester) async {
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
    });
  }, skip: skipReason);
}
