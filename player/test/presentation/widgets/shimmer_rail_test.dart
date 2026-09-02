import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/rail_metrics.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/shimmer_card.dart';
import 'package:shimmer/shimmer.dart';

import '../../test_utils/rail_parity.dart';

Future<void> _pumpSkeleton(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: ShimmerRail())),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  runRailSkeletonParity();

  group('ShimmerRail', () {
    testWidgets('rounds its posters at the shared poster radius',
        (tester) async {
      await _pumpSkeleton(tester, const Size(1400, 900));

      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(ShimmerRail.posterKeyAt(0)),
          matching: find.byType(DecoratedBox),
        ),
      );
      final decoration = box.decoration as BoxDecoration;

      expect(
        decoration.borderRadius,
        const BorderRadius.all(Radius.circular(DepthTokens.radiusPoster)),
      );
    });

    testWidgets('runs one shimmer for the whole rail, not one per card',
        (tester) async {
      await _pumpSkeleton(tester, const Size(1400, 900));

      expect(find.byType(Shimmer), findsOneWidget);
    });

    testWidgets('fills the viewport to its right edge', (tester) async {
      const size = Size(1400, 900);
      await _pumpSkeleton(tester, size);

      final context = tester.element(find.byType(ShimmerRail));
      final metrics = RailMetrics.of(context);
      final perCard = metrics.cardSize.width + metrics.cardSpacing;
      final lastOnScreen = (size.width / perCard).ceil() - 1;

      // The card straddling the right edge must exist and must cross it. A
      // fixed count of five left the right third of a desktop rail blank until
      // real cards arrived, which is the same jump on the other axis.
      final last =
          tester.getRect(find.byKey(ShimmerRail.posterKeyAt(lastOnScreen)));

      expect(
        last.right,
        greaterThan(size.width),
        reason: 'the rail must run past the viewport, leaving no empty tail',
      );
    });

    testWidgets('an explicit count overrides the derived one', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ShimmerRail(count: 2))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(ShimmerRail.posterKeyAt(1)), findsOneWidget);
      expect(find.byKey(ShimmerRail.posterKeyAt(2)), findsNothing);
    });
  });
}
