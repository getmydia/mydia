// U3 — glass sidebar (plan R4, R6, R10).
//
// The desktop sidebar is a real-blur glass panel ([GlassSidebarPanel]) over the
// shell ambient backdrop: it samples and is tinted by the artwork (R5), defines
// its right edge with the light rim (R6), and keeps a fill opacity at or above
// the legibility floor so nav labels stay readable over any backdrop (R10).

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/nav/desktop_sidebar.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            // Stand-in for the ambient backdrop the real shell paints behind
            // the sidebar; the live blur samples whatever is behind it.
            const Positioned.fill(child: ColoredBox(color: Colors.white)),
            Row(children: [child]),
          ],
        ),
      ),
    );

BackdropFilter _backdropOf(WidgetTester tester) =>
    tester.widget<BackdropFilter>(find.byType(BackdropFilter));

DecoratedBox _glassFillOf(WidgetTester tester) => tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(BackdropFilter),
        matching: find.byType(DecoratedBox),
      ),
    );

void main() {
  group('GlassSidebarPanel', () {
    testWidgets('renders a real-blur BackdropFilter at the chrome sigma',
        (tester) async {
      await tester.pumpWidget(
        _host(const GlassSidebarPanel(child: SizedBox.expand())),
      );

      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(
        _backdropOf(tester).filter,
        ImageFilter.blur(
          sigmaX: DepthTokens.blurChrome,
          sigmaY: DepthTokens.blurChrome,
        ),
      );
    });

    testWidgets('defines its right edge with the light rim (R6)',
        (tester) async {
      await tester.pumpWidget(
        _host(const GlassSidebarPanel(child: SizedBox.expand())),
      );

      final decoration = _glassFillOf(tester).decoration as BoxDecoration;
      final border = decoration.border as Border;
      expect(border.right.color, DepthTokens.rimColor);
      expect(border.right.width, DepthTokens.rimWidth);
      // It is an edge, not a full box border.
      expect(border.left, BorderSide.none);
    });

    testWidgets(
        'glass fill clears the legibility floor and is translucent '
        '(R6/R10)', (tester) async {
      await tester.pumpWidget(
        _host(const GlassSidebarPanel(child: SizedBox.expand())),
      );

      final decoration = _glassFillOf(tester).decoration as BoxDecoration;
      final fill = decoration.color!;
      // R10: at or above the legibility floor.
      expect(fill.a, greaterThanOrEqualTo(DepthTokens.glassLegibilityFloor));
      // R6: no longer a flat full-opacity background fill.
      expect(fill.a, lessThan(1.0));
    });

    testWidgets('carries a layered chrome shadow for depth', (tester) async {
      await tester.pumpWidget(
        _host(const GlassSidebarPanel(child: SizedBox.expand())),
      );

      final shadowed =
          tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
      final hasChromeShadow = shadowed.any((d) {
        final deco = d.decoration;
        return deco is BoxDecoration &&
            deco.boxShadow != null &&
            deco.boxShadow!.isNotEmpty;
      });
      expect(hasChromeShadow, isTrue);
    });

    testWidgets('renders its child content', (tester) async {
      await tester.pumpWidget(
        _host(const GlassSidebarPanel(child: Text('nav'))),
      );
      expect(find.text('nav'), findsOneWidget);
    });
  });
}
