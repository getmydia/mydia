// Pins a LAYOUT CONTRACT: how a pinned `SliverAppBar`'s `leading` widget
// responds when the ambient `MediaQuery` carries a reserved top strip,
// including across scroll as the app bar collapses. `_detailScreenLike`
// below reproduces the `CustomScrollView` + pinned `SliverAppBar` shape
// shared by `movie_detail_screen.dart`, `show_detail_screen.dart` and
// `episode_detail_screen.dart`, rather than mounting any of them directly —
// those screens need a provider graph, a GraphQL client and a router
// location this suite does not construct. That means this file proves the
// contract `SliverAppBar` already honours, not that the three real screens
// still build this exact shape.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/window_chrome_inset.dart';

const Key _backKey = Key('detail-back');

/// The structure every detail screen shares: a `CustomScrollView` whose first
/// sliver is a pinned `SliverAppBar` carrying the back button as `leading`.
/// Mirrors `movie_detail_screen.dart`, `show_detail_screen.dart` and
/// `episode_detail_screen.dart`, none of which can be mounted here without
/// their provider graphs.
Widget _detailScreenLike({required EdgeInsets padding}) => MediaQuery(
      data: MediaQueryData(padding: padding),
      child: const MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: 380,
                pinned: true,
                leading: Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.arrow_back_rounded, key: _backKey),
                ),
                flexibleSpace: FlexibleSpaceBar(
                  background: ColoredBox(color: Colors.blue),
                ),
              ),
              SliverToBoxAdapter(child: SizedBox(height: 2000)),
            ],
          ),
        ),
      ),
    );

void main() {
  group('detail screen back button vs the macOS traffic lights', () {
    testWidgets(
        'REGRESSION WITNESS: with no reserved strip the back icon lands '
        'inside the traffic light zone', (tester) async {
      await tester.pumpWidget(_detailScreenLike(padding: EdgeInsets.zero));

      // Measured: (8, 8) - (48, 48). The lights occupy roughly x 7-75,
      // y 8-28, so this is the bug this whole change exists to fix. The test
      // documents it rather than asserting the app ships it.
      expect(
        tester.getRect(find.byKey(_backKey)).top,
        lessThan(kMacTitleBarOverlap),
      );
    });

    testWidgets('the reserved strip moves the back icon clear', (tester) async {
      await tester.pumpWidget(
        _detailScreenLike(
          padding: const EdgeInsets.only(top: kMacTitleBarOverlap),
        ),
      );

      // Measured: (8, 36) - (48, 76).
      expect(
        tester.getRect(find.byKey(_backKey)).top,
        greaterThanOrEqualTo(kMacTitleBarOverlap),
      );
    });

    testWidgets('it still clears once the hero collapses under scroll',
        (tester) async {
      await tester.pumpWidget(
        _detailScreenLike(
          padding: const EdgeInsets.only(top: kMacTitleBarOverlap),
        ),
      );

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();

      expect(
        tester.getRect(find.byKey(_backKey)).top,
        greaterThanOrEqualTo(kMacTitleBarOverlap),
      );
    });
  });
}
