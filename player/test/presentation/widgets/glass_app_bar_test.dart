// U4 — glass top bars and overlays (plan R4, R10).
//
// The top bars run through the centralized `GlassSurface.appBar` preset, which
// U2 token-ized. This asserts the bar glass resolves to the chrome blur sigma
// and that its fill — at both the default opacity and the 0.85 used by the
// library/downloads bars — clears the R10 legibility floor while staying
// translucent enough to be tinted by the ambient backdrop behind it.

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.white)),
            child,
          ],
        ),
      ),
    );

BackdropFilter _backdropOf(WidgetTester tester) =>
    tester.widget<BackdropFilter>(find.byType(BackdropFilter));

BoxDecoration _fillOf(WidgetTester tester) => tester
    .widget<DecoratedBox>(
      find.descendant(
        of: find.byType(BackdropFilter),
        matching: find.byType(DecoratedBox),
      ),
    )
    .decoration as BoxDecoration;

void main() {
  group('GlassSurface.appBar token glass (R4/R10)', () {
    testWidgets('default bar: chrome sigma + fill clears the legibility floor',
        (tester) async {
      await tester.pumpWidget(
        _host(const GlassSurface.appBar(child: SizedBox(height: 56))),
      );

      expect(
        _backdropOf(tester).filter,
        ImageFilter.blur(
          sigmaX: DepthTokens.blurChrome,
          sigmaY: DepthTokens.blurChrome,
        ),
      );

      final fill = _fillOf(tester).color!;
      expect(fill.a, greaterThanOrEqualTo(DepthTokens.glassLegibilityFloor));
      // Translucent so the ambient backdrop tints it (R5).
      expect(fill.a, lessThan(1.0));
      expect(
          fill,
          AppColors.background
              .withValues(alpha: DepthTokens.chromeFillOpacity));
    });

    testWidgets('library/downloads bar (opacity 0.85) clears the floor',
        (tester) async {
      await tester.pumpWidget(
        _host(const GlassSurface.appBar(opacity: 0.85, child: SizedBox())),
      );

      final fill = _fillOf(tester).color!;
      expect(fill.a, greaterThanOrEqualTo(DepthTokens.glassLegibilityFloor));
      expect(fill, AppColors.background.withValues(alpha: 0.85));
    });
  });
}
