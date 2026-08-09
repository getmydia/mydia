// U10 — scroll-jank structural verification (plan R8; AE3).
//
// The performance split is enforced structurally: real BackdropFilter blur is
// confined to the fixed/low-count chrome (sidebar, top bar), while scrolling
// content (rails, grids) uses faux-glass with no live blur. We mount fixed
// chrome alongside a populated rail and assert the rail subtree contains zero
// BackdropFilter — before and after a scroll — while the fixed chrome carries
// the only blur passes.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/recently_added_item.dart';
import 'package:player/presentation/widgets/nav/desktop_sidebar.dart';
import 'package:player/presentation/widgets/content_rail.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

List<RecentlyAddedItem> _items(int n) => List.generate(
      n,
      (i) => RecentlyAddedItem(id: '$i', type: 'movie', title: 'Title $i'),
    );

Widget _scene() => ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              // Fixed chrome — real-blur surfaces.
              GlassSurface.appBar(child: const SizedBox(height: 56)),
              Expanded(
                child: Row(
                  children: [
                    const GlassSidebarPanel(child: SizedBox.expand()),
                    // Scrolling content — faux-glass, no live blur.
                    Expanded(
                      child: ContentRail(title: 'Rail', items: _items(20)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

void main() {
  group('blur budget split (R8/AE3)', () {
    testWidgets(
        'rail subtree has no BackdropFilter; fixed chrome carries the '
        'only blur passes', (tester) async {
      await tester.pumpWidget(_scene());
      await tester.pump();

      // The scrolling rail uses faux-glass — zero live blur in its subtree.
      expect(
        find.descendant(
          of: find.byType(ContentRail),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );

      // Real blur is confined to the two fixed surfaces (app bar + sidebar).
      expect(find.byType(BackdropFilter), findsNWidgets(2));
    });

    testWidgets('scrolling the rail introduces no live blur', (tester) async {
      await tester.pumpWidget(_scene());
      await tester.pump();

      await tester.drag(find.byType(ContentRail), const Offset(-400, 0));
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(ContentRail),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
      // Still exactly the two fixed-surface blur passes.
      expect(find.byType(BackdropFilter), findsNWidgets(2));
    });
  });
}
