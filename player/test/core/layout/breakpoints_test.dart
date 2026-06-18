import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/breakpoints.dart';

/// Pumps a probe widget at the given logical [width] and returns the
/// [BuildContext] beneath a [MediaQuery] of that size, so the responsive
/// helpers can be exercised across tiers.
Future<BuildContext> _contextAtWidth(WidgetTester tester, double width) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: Size(width, 800)),
      child: Builder(
        builder: (context) {
          captured = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  // Representative widths for the three card-size tiers. getEpisodeCardSize
  // (like getCardSize) branches on `>= desktop` (1200) and `>= tablet` (900),
  // so the tiers are: smallest < 900, medium 900-1199, largest >= 1200.
  const mobileWidth = 400.0;
  const tabletWidth = 1000.0;
  const desktopWidth = 1400.0;

  group('Breakpoints.getEpisodeCardSize', () {
    testWidgets('is ~16:9 at each tier', (tester) async {
      for (final width in [mobileWidth, tabletWidth, desktopWidth]) {
        final context = await _contextAtWidth(tester, width);
        final size = Breakpoints.getEpisodeCardSize(context);
        expect(
          size.aspectRatio,
          closeTo(16 / 9, 0.05),
          reason: 'aspect ratio off at width $width',
        );
      }
    });

    testWidgets('card width increases mobile → tablet → desktop',
        (tester) async {
      // Read each size immediately after its pump — re-pumping deactivates the
      // previous probe context and its MediaQuery.
      final mobileWidth0 = Breakpoints.getEpisodeCardSize(
              await _contextAtWidth(tester, mobileWidth))
          .width;
      final tabletWidth0 = Breakpoints.getEpisodeCardSize(
              await _contextAtWidth(tester, tabletWidth))
          .width;
      final desktopWidth0 = Breakpoints.getEpisodeCardSize(
              await _contextAtWidth(tester, desktopWidth))
          .width;

      expect(mobileWidth0, lessThan(tabletWidth0));
      expect(tabletWidth0, lessThan(desktopWidth0));
    });
  });

  group('Breakpoints.getEpisodeRailHeight', () {
    testWidgets(
        'exceeds the card height at each tier (room for the label strip)',
        (tester) async {
      for (final width in [mobileWidth, tabletWidth, desktopWidth]) {
        final context = await _contextAtWidth(tester, width);
        final railHeight = Breakpoints.getEpisodeRailHeight(context);
        final cardHeight = Breakpoints.getEpisodeCardSize(context).height;
        expect(
          railHeight,
          greaterThan(cardHeight),
          reason: 'rail height should exceed card height at width $width',
        );
      }
    });
  });
}
