import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/glass_accessibility.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_adaptive.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/presentation/widgets/glass/liquid_glass_filter.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

Widget _host(Widget child,
        {GlassAccessibility access = GlassAccessibility.none}) =>
    MaterialApp(
      home: GlassAccessibilityScope(
        value: access,
        child: Scaffold(
          body: Center(child: SizedBox(width: 120, height: 48, child: child)),
        ),
      ),
    );

const _box = SizedBox.expand();

void main() {
  tearDown(() {
    LiquidGlassSupport.debugOverride = null;
  });

  final liquidVariants = <String, Widget>{
    'chrome': const GlassSurface.chrome(child: _box),
    'modal': GlassSurface.modal(child: _box),
    'control': GlassSurface.control(
        borderRadius: BorderRadius.circular(24), child: _box),
  };

  final neverLiquid = <String, Widget>{
    'osd': GlassSurface.osd(child: _box),
    'faux': const GlassSurface.faux(child: _box),
    'hoverOverlay': GlassSurface.hoverOverlay(child: _box),
  };

  group('when Liquid Glass is available', () {
    setUp(() => LiquidGlassSupport.debugOverride = true);

    liquidVariants.forEach((name, surface) {
      testWidgets('$name takes the Liquid Glass recipe', (tester) async {
        await tester.pumpWidget(_host(surface));
        expect(find.byType(LiquidGlassFilter), findsOneWidget);
        expect(find.byType(BackdropFilter), findsNothing);
      });
    });

    testWidgets('appBar takes the scroll edge band', (tester) async {
      await tester.pumpWidget(_host(const GlassSurface.appBar(child: _box)));
      expect(find.byType(LiquidGlassFilter), findsNothing);
      final backdrop =
          tester.widget<BackdropFilter>(find.byType(BackdropFilter));
      expect(
          backdrop.filter,
          ImageFilter.blur(
            sigmaX: DepthTokens.liquidScrollEdgeBlurSigma,
            sigmaY: DepthTokens.liquidScrollEdgeBlurSigma,
          ));
      final box = tester.widget<DecoratedBox>(find.descendant(
        of: find.byType(BackdropFilter),
        matching: find.byType(DecoratedBox),
      ));
      final gradient =
          (box.decoration as BoxDecoration).gradient! as LinearGradient;
      expect(gradient.colors.first.a,
          closeTo(DepthTokens.liquidScrollEdgeTopOpacity, 0.002));
      expect(gradient.colors.last.a,
          closeTo(DepthTokens.liquidScrollEdgeBottomOpacity, 0.002));
    });

    LiquidGlassFilter filterOf(WidgetTester tester) =>
        tester.widget<LiquidGlassFilter>(find.byType(LiquidGlassFilter));

    testWidgets('chrome, modal and control use their adaptive roles',
        (tester) async {
      await tester.pumpWidget(_host(const GlassSurface.chrome(child: _box)));
      var f = filterOf(tester);
      expect(f.tint.a, closeTo(DepthTokens.liquidChromeTintOpacity, 0.002));
      expect(f.adaptiveTintMax, DepthTokens.liquidChromeAdaptiveMax);

      await tester.pumpWidget(_host(GlassSurface.modal(child: _box)));
      f = filterOf(tester);
      expect(f.tint.a, closeTo(DepthTokens.liquidModalTintOpacity, 0.002));
      expect(f.adaptiveTintMax, DepthTokens.liquidModalAdaptiveMax);

      await tester.pumpWidget(_host(GlassSurface.control(
          borderRadius: BorderRadius.circular(24), child: _box)));
      f = filterOf(tester);
      expect(f.tint.a, closeTo(DepthTokens.liquidControlTintOpacity, 0.002));
      expect(f.adaptiveTintMax, DepthTokens.liquidControlAdaptiveMax);
    });

    testWidgets('prominent white control never adapts', (tester) async {
      await tester.pumpWidget(_host(GlassSurface.control(
        borderRadius: BorderRadius.circular(24),
        prominentColor: Colors.white,
        child: _box,
      )));
      expect(filterOf(tester).adaptiveTintMax, isNull);
    });

    testWidgets('accent control uses the accent glass tint', (tester) async {
      const accent = Color(0xFF0A84FF);
      await tester.pumpWidget(_host(GlassSurface.control(
        borderRadius: BorderRadius.circular(24),
        accentColor: accent,
        child: _box,
      )));
      final f = filterOf(tester);
      expect(
          f.tint,
          accentGlassTint(accent)
              .withValues(alpha: DepthTokens.liquidAccentTintOpacity));
      expect(f.adaptiveTintMax, DepthTokens.liquidAccentAdaptiveMax);
    });

    testWidgets('control paints the control shadow', (tester) async {
      await tester.pumpWidget(_host(GlassSurface.control(
          borderRadius: BorderRadius.circular(24), child: _box)));
      final shadowBox = tester.widgetList<DecoratedBox>(find.ancestor(
        of: find.byType(LiquidGlassFilter),
        matching: find.byType(DecoratedBox),
      ));
      expect(
        shadowBox.any((b) =>
            (b.decoration as BoxDecoration).boxShadow ==
            DepthTokens.liquidControlShadow),
        isTrue,
      );
    });

    testWidgets('Increase Contrast boosts the adaptive max too',
        (tester) async {
      await tester.pumpWidget(_host(
        const GlassSurface.chrome(child: _box),
        access: const GlassAccessibility(increaseContrast: true),
      ));
      expect(
        filterOf(tester).adaptiveTintMax,
        closeTo(
          (DepthTokens.liquidChromeAdaptiveMax +
                  DepthTokens.liquidHighContrastTintBoost)
              .clamp(0.0, 1.0),
          0.002,
        ),
      );
    });

    testWidgets('Reduce Transparency on appBar is solid', (tester) async {
      await tester.pumpWidget(_host(
        const GlassSurface.appBar(child: _box),
        access: const GlassAccessibility(reduceTransparency: true),
      ));
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(LiquidGlassFilter), findsNothing);
    });

    neverLiquid.forEach((name, surface) {
      testWidgets('$name never takes the Liquid Glass recipe', (tester) async {
        await tester.pumpWidget(_host(surface));
        expect(find.byType(LiquidGlassFilter), findsNothing);
      });
    });

    testWidgets('the tint carries the liquid chrome opacity', (tester) async {
      await tester.pumpWidget(
          _host(const GlassSurface.chrome(opacity: 0.9, child: _box)));
      final filter =
          tester.widget<LiquidGlassFilter>(find.byType(LiquidGlassFilter));
      expect(
          filter.tint.a, closeTo(DepthTokens.liquidChromeTintOpacity, 0.002));
    });

    testWidgets('prominent control is tinted its colour', (tester) async {
      await tester.pumpWidget(_host(GlassSurface.control(
        borderRadius: BorderRadius.circular(24),
        prominentColor: Colors.white,
        child: _box,
      )));
      final filter =
          tester.widget<LiquidGlassFilter>(find.byType(LiquidGlassFilter));
      expect(
          filter.tint,
          Colors.white
              .withValues(alpha: DepthTokens.liquidProminentTintOpacity));
    });

    testWidgets('Reduce Transparency gives a solid fill, no backdrop',
        (tester) async {
      await tester.pumpWidget(_host(
        const GlassSurface.chrome(child: _box),
        access: const GlassAccessibility(reduceTransparency: true),
      ));
      expect(find.byType(LiquidGlassFilter), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      final box = tester.widget<DecoratedBox>(find.descendant(
        of: find.byType(GlassSurface),
        matching: find.byType(DecoratedBox),
      ));
      final color = (box.decoration as BoxDecoration).color;
      expect(color?.a, 1.0);
    });

    testWidgets('Reduce Transparency keeps the modal palette border',
        (tester) async {
      await tester.pumpWidget(_host(
        GlassSurface.modal(child: _box),
        access: const GlassAccessibility(reduceTransparency: true),
      ));
      final box = tester.widget<DecoratedBox>(find.descendant(
        of: find.byType(GlassSurface),
        matching: find.byType(DecoratedBox),
      ));
      expect((box.decoration as BoxDecoration).border, isNotNull);
    });

    testWidgets('Increase Contrast raises the tint and draws a rim',
        (tester) async {
      await tester.pumpWidget(_host(
        const GlassSurface.chrome(child: _box),
        access: const GlassAccessibility(increaseContrast: true),
      ));
      final filter =
          tester.widget<LiquidGlassFilter>(find.byType(LiquidGlassFilter));
      expect(
        filter.tint.a,
        closeTo(
          DepthTokens.liquidChromeTintOpacity +
              DepthTokens.liquidHighContrastTintBoost,
          0.002,
        ),
      );
      final box = tester.widget<DecoratedBox>(find.descendant(
        of: find.byType(LiquidGlassFilter),
        matching: find.byType(DecoratedBox),
      ));
      expect((box.decoration as BoxDecoration).border, isNotNull);
    });
  });

  group('when Liquid Glass is not available', () {
    testWidgets('appBar keeps its frosted recipe', (tester) async {
      await tester.pumpWidget(_host(const GlassSurface.appBar(child: _box)));
      expect(find.byType(LiquidGlassFilter), findsNothing);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('accent control fills at the alpha its label is rated at',
        (tester) async {
      LiquidGlassSupport.debugOverride = false;
      const accent = Color(0xFF0A84FF);
      await tester.pumpWidget(_host(GlassSurface.control(
        borderRadius: BorderRadius.circular(24),
        accentColor: accent,
        child: _box,
      )));
      final box = tester.widget<DecoratedBox>(find.descendant(
        of: find.byType(BackdropFilter),
        matching: find.byType(DecoratedBox),
      ));
      expect(
          (box.decoration as BoxDecoration).color,
          accentGlassTint(accent)
              .withValues(alpha: DepthTokens.liquidAccentAdaptiveMax));
    });

    liquidVariants.forEach((name, surface) {
      testWidgets('$name keeps its frosted recipe', (tester) async {
        await tester.pumpWidget(_host(surface));
        expect(find.byType(LiquidGlassFilter), findsNothing);
        expect(find.byType(BackdropFilter), findsOneWidget);
      });
    });

    testWidgets('Reduce Transparency still applies on Apple', (tester) async {
      await tester.pumpWidget(_host(
        const GlassSurface.chrome(child: _box),
        access: const GlassAccessibility(reduceTransparency: true),
      ));
      expect(find.byType(BackdropFilter), findsNothing);
    });
  });
}
