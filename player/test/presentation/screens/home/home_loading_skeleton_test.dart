// The loading state's own geometry, as distinct from the rails inside it
// (which `rail_parity.dart` covers).
//
// Both assertions here pin a real defect fixed on 2026-09-01. The skeleton
// list carried a top padding of `safeAreaTop + kToolbarHeight` while the
// loaded `CustomScrollView` carried none under a Scaffold with
// `extendBodyBehindAppBar: true`, so the hero jumped up by roughly 80 to 100px
// on load. The skeleton also inserted spacers between its rails that the
// loaded layout does not have.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/home/home_loading_skeleton.dart';
import 'package:player/presentation/widgets/shimmer_card.dart';

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: HomeLoadingSkeleton())),
  );
  // Never pumpAndSettle: ShimmerRail animates forever.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('HomeLoadingSkeleton', () {
    testWidgets('the hero starts at the top of the scroll view',
        (tester) async {
      await _pump(tester, const Size(390, 844));

      // .first: ShimmerRail's horizontal card strip is itself a ListView, so
      // the finder is ambiguous once a rail is built. The outer, vertical one
      // is first in traversal order.
      final listTop = tester.getTopLeft(find.byType(ListView).first).dy;
      final heroTop =
          tester.getTopLeft(find.byKey(HomeLoadingSkeleton.heroKey)).dy;

      expect(heroTop, listTop,
          reason: 'the loaded CustomScrollView has no top padding either');
    });

    testWidgets('no spacer sits between the rails', (tester) async {
      await _pump(tester, const Size(390, 844));

      final rails = find.byType(ShimmerRail);
      expect(rails, findsAtLeastNWidgets(2));

      expect(
        tester.getTopLeft(rails.at(1)).dy,
        tester.getBottomLeft(rails.at(0)).dy,
        reason: 'rails are separated by headerTopPadding alone',
      );
    });

    testWidgets('draws a hero and three rails', (tester) async {
      // Tall enough that the hero and all three rails land inside the
      // sliver's default cache extent; 900 leaves the third rail unbuilt at
      // this breakpoint's sizes, which is a viewport artifact, not a defect.
      await _pump(tester, const Size(1400, 3000));

      expect(find.byKey(HomeLoadingSkeleton.heroKey), findsOneWidget);
      expect(find.byType(ShimmerRail), findsNWidgets(3));
    });
  });
}
