// Unit coverage for the dock-clearance reader. The real 83/117 dock heights
// are NOT asserted here; they belong to the widget under test and are covered
// by app_shell_dock_inset_test.dart. This file pins the arithmetic only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/dock_insets.dart';

/// A mobile width: below Breakpoints.tablet (900).
const Size kMobileSize = Size(400, 800);

/// A desktop width: at or above Breakpoints.tablet (900).
const Size kDesktopSize = Size(1200, 900);

/// Reads `DockInsets.bottomOf` under a synthetic ambient MediaQuery.
Future<double> readBottomOf(
  WidgetTester tester, {
  required Size size,
  required double inset,
}) async {
  late double value;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: size,
        padding: EdgeInsets.only(bottom: inset),
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            value = DockInsets.bottomOf(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return value;
}

void main() {
  group('DockInsets.bottomOf', () {
    testWidgets('on mobile returns the ambient bottom inset plus the gap',
        (tester) async {
      expect(
        await readBottomOf(tester, size: kMobileSize, inset: 117),
        117 + DockInsets.dockGap,
      );
    });

    testWidgets('on mobile with no inset returns just the gap', (tester) async {
      expect(
        await readBottomOf(tester, size: kMobileSize, inset: 0),
        DockInsets.dockGap,
      );
    });

    testWidgets('on desktop returns the desktop gap and ignores the inset',
        (tester) async {
      expect(
        await readBottomOf(tester, size: kDesktopSize, inset: 34),
        DockInsets.desktopGap,
      );
    });

    testWidgets('preserves the pre-existing desktop spacing of 32',
        (tester) async {
      // The eight screens this replaces all used `isDesktop ? 32.0 : 100.0`.
      // Desktop must not shift by a single pixel.
      expect(DockInsets.desktopGap, 32);
    });
  });

  group('DockGap', () {
    testWidgets('sizes itself to the dock clearance', (tester) async {
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(
            size: kMobileSize,
            padding: EdgeInsets.only(bottom: 117),
          ),
          child: Directionality(
            textDirection: TextDirection.ltr,
            // Align, so DockGap is measured under LOOSE constraints. The test
            // binding's root is a tight 800x600; a bare SizedBox under it is
            // forced to the full 600 by BoxConstraints.enforce, and getSize
            // would report the viewport height rather than the gap.
            child: Align(
              alignment: Alignment.topLeft,
              child: DockGap(),
            ),
          ),
        ),
      );

      expect(
        tester.getSize(find.byType(DockGap)).height,
        117 + DockInsets.dockGap,
      );
    });
  });

  group('SliverDockGap', () {
    testWidgets('reserves the dock clearance at the end of a sliver list',
        (tester) async {
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(
            size: kMobileSize,
            padding: EdgeInsets.only(bottom: 117),
          ),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: SizedBox(height: 200)),
                SliverDockGap(),
              ],
            ),
          ),
        ),
      );

      expect(
        tester.getSize(find.byType(DockGap)).height,
        117 + DockInsets.dockGap,
      );
    });
  });
}
