import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/rail_metrics.dart';

/// Resolves `RailMetrics` at a given viewport by pumping a widget that reads
/// it. `RailMetrics.of` needs a `BuildContext`, so there is no way to call it
/// from a plain unit test.
Future<RailMetrics> metricsAt(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  late RailMetrics captured;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          captured = RailMetrics.of(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  group('RailMetrics.of', () {
    testWidgets('resolves the mobile tier below 900', (tester) async {
      final m = await metricsAt(tester, const Size(599, 800));

      expect(m.cardSize.width, 130);
      expect(m.cardSize.height, 195);
      expect(m.cardSpacing, 16);
      expect(m.horizontalPadding, 20);
      expect(m.railHeight, 260);
      expect(m.headerTopPadding, 24);
      expect(m.headerBottomPadding, 16);
      expect(m.headerBottomCollapsed, 8);
    });

    testWidgets('resolves the tablet tier between 900 and 1199',
        (tester) async {
      final m = await metricsAt(tester, const Size(1000, 800));

      expect(m.cardSize.width, 145);
      expect(m.cardSize.height, 218);
      expect(m.cardSpacing, 20);
      expect(m.horizontalPadding, 24);
      expect(m.railHeight, 300);
    });

    testWidgets('resolves the desktop tier from 1200', (tester) async {
      final m = await metricsAt(tester, const Size(1400, 900));

      expect(m.cardSize.width, 160);
      expect(m.cardSize.height, 240);
      expect(m.cardSpacing, 24);
      expect(m.horizontalPadding, 32);
      expect(m.railHeight, 340);
      expect(m.headerTopPadding, 32);
      expect(m.headerBottomPadding, 20);
      expect(m.headerBottomCollapsed, 10);
    });

    testWidgets('header padding switches at 900 and card size at 1200',
        (tester) async {
      // The trap this class exists to survive. `Breakpoints.isDesktop` is true
      // from 900 while `Breakpoints.desktop` is 1200, so at 1000 the header is
      // already on its wide padding while the cards are still tablet-sized. An
      // implementation that collapsed the two thresholds into one branch would
      // pass at 599 and 1400 and fail only here.
      final m = await metricsAt(tester, const Size(1000, 800));

      expect(m.headerTopPadding, 32, reason: 'isDesktop is true from 900');
      expect(m.cardSize.width, 145, reason: 'desktop cards start at 1200');
    });

    testWidgets('card and label gaps are the MediaCard values', (tester) async {
      expect(RailMetrics.labelGap, 10);
      expect(RailMetrics.subtitleGap, 4);
    });
  });
}
