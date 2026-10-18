import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/glass_accessibility.dart';
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
    'appBar': const GlassSurface.appBar(child: _box),
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
