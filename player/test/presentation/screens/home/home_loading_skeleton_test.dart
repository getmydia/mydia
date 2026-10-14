// The loading state's own geometry, as distinct from the rails inside it.
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
import 'package:player/presentation/screens/sources/continue_watching_card.dart';

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: HomeLoadingSkeleton())),
  );
  // Never pumpAndSettle: the rails animate forever.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('HomeLoadingSkeleton', () {
    testWidgets('the hero starts at the top of the scroll view',
        (tester) async {
      await _pump(tester, const Size(390, 844));

      // .first: each rail's horizontal card strip is itself a ListView, so
      // the finder is ambiguous once a rail is built. The outer, vertical one
      // is first in traversal order.
      final listTop = tester.getTopLeft(find.byType(ListView).first).dy;
      final heroTop =
          tester.getTopLeft(find.byKey(HomeLoadingSkeleton.heroKey)).dy;

      expect(heroTop, listTop,
          reason: 'the loaded CustomScrollView has no top padding either');
    });

    testWidgets('the hero sits at y=0 under a transparent app bar',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            extendBodyBehindAppBar: true,
            appBar: PreferredSize(
              preferredSize: Size.fromHeight(56),
              // Sized: an empty SizedBox shrinks to zero under the Scaffold's
              // loose constraints and the bar would claim no height.
              child: SizedBox(height: 56),
            ),
            body: HomeLoadingSkeleton(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Inside extendBodyBehindAppBar a ListView with null padding inherits
      // the bar's height as top padding, which pushed the hero under the bar.
      expect(
        tester.getTopLeft(find.byKey(HomeLoadingSkeleton.heroKey)).dy,
        0,
      );
    });

    testWidgets('the hero placeholder is the loaded poster card at its offset',
        (tester) async {
      await _pump(tester, const Size(1280, 800));

      final poster = find.byKey(HomeLoadingSkeleton.heroPosterKey);
      expect(tester.getSize(poster), const Size(248, 360));
      // The loaded hero pads its top by the safe area plus 24.
      expect(tester.getTopLeft(poster).dy, 24);
    });

    testWidgets('narrow, the placeholder poster is 60% wide and centred',
        (tester) async {
      await _pump(tester, const Size(400, 800));

      final poster = find.byKey(HomeLoadingSkeleton.heroPosterKey);
      expect(tester.getSize(poster).width, 240);
      expect(tester.getCenter(poster).dx, 200);
    });

    testWidgets('the first rail draws 280-wide landscape cards',
        (tester) async {
      await _pump(tester, const Size(1280, 3000));

      final first = find.byKey(HomeLoadingSkeleton.railKey).first;
      final card = find.descendant(
        of: first,
        matching: find.byWidgetPredicate(
          (w) => w is SizedBox && w.width == 280,
        ),
      );
      expect(card, findsWidgets);
      expect(
        tester.getSize(card.first).height,
        ContinueWatchingCard.heightFor(
          tester.element(card.first),
          hasCaption: true,
        ),
      );
    });

    testWidgets('no spacer sits between the rails', (tester) async {
      // Tall: the stacked hero is as tall as the loaded one, which leaves
      // the second rail unbuilt in an 844 px viewport.
      await _pump(tester, const Size(390, 2400));

      final rails = find.byKey(HomeLoadingSkeleton.railKey);
      expect(rails, findsAtLeastNWidgets(2));

      expect(
        tester.getTopLeft(rails.at(1)).dy,
        tester.getBottomLeft(rails.at(0)).dy,
        reason: 'rails are separated by their own heading padding alone',
      );
    });

    testWidgets('the sizing text never reaches the semantics tree',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const Size(1400, 3000));

      expect(find.bySemanticsLabel('M'), findsNothing);
      expect(find.bySemanticsLabel(RegExp(r'^M(\nM)*$')), findsNothing);
      handle.dispose();
    });

    testWidgets('draws a hero and three rails', (tester) async {
      // Tall enough that the hero and all three rails land inside the
      // sliver's default cache extent; 900 leaves the third rail unbuilt at
      // this breakpoint's sizes, which is a viewport artifact, not a defect.
      await _pump(tester, const Size(1400, 3000));

      expect(find.byKey(HomeLoadingSkeleton.heroKey), findsOneWidget);
      expect(find.byKey(HomeLoadingSkeleton.railKey), findsNWidgets(3));
    });
  });
}
