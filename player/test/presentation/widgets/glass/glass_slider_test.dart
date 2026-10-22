import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/glass_accessibility.dart';
import 'package:player/core/theme/liquid_glass/liquid_geometry.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_profile.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/glass/glass_slider.dart';
import 'package:player/presentation/widgets/glass/liquid_glass_filter.dart';

const _width = 300.0;

Widget _host({
  required bool liquid,
  double value = 0.5,
  ValueChanged<double>? onChanged,
  bool reduceTransparency = false,
}) =>
    MaterialApp(
      theme: AppTheme.build(Palettes.projectionBooth, liquid: liquid),
      home: GlassAccessibilityScope(
        value: GlassAccessibility(reduceTransparency: reduceTransparency),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: _width,
              child: GlassSlider(value: value, onChanged: onChanged ?? (_) {}),
            ),
          ),
        ),
      ),
    );

double _knobCentreX(WidgetTester tester) =>
    tester.getCenter(find.byType(LiquidGlassFilter)).dx;

void main() {
  testWidgets('frosted renders the Material slider and no glass knob',
      (tester) async {
    await tester.pumpWidget(_host(liquid: false));
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(LiquidGlassFilter), findsNothing);
  });

  testWidgets('liquid hides the thumb and adds one clear 37x24 lens',
      (tester) async {
    await tester.pumpWidget(_host(liquid: true));
    final theme = tester.widget<SliderTheme>(find
        .ancestor(of: find.byType(Slider), matching: find.byType(SliderTheme))
        .first);
    expect(theme.data.thumbShape!.getPreferredSize(true, false), Size.zero);
    final filter =
        tester.widget<LiquidGlassFilter>(find.byType(LiquidGlassFilter));
    expect(filter.profile, LiquidGlassProfile.clear);
    final box = find.ancestor(
        of: find.byType(LiquidGlassFilter), matching: find.byType(SizedBox));
    expect(
        tester.getSize(box.first),
        const Size(
            LiquidGeometry.sliderKnobWidth, LiquidGeometry.sliderKnobHeight));
  });

  testWidgets('the knob centre tracks the value across the track',
      (tester) async {
    await tester.pumpWidget(_host(liquid: true, value: 0));
    final left = _knobCentreX(tester);
    await tester.pumpWidget(_host(liquid: true, value: 1));
    final right = _knobCentreX(tester);
    expect(right - left, closeTo(_width - LiquidGeometry.sliderKnobWidth, 1));
  });

  testWidgets('dragging reports changes and presses the knob', (tester) async {
    final values = <double>[];
    await tester.pumpWidget(_host(liquid: true, onChanged: values.add));
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(Slider)));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(values, isNotEmpty);
    final scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
    expect(scale.scale, DepthTokens.liquidPressScale);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1.0);
  });

  testWidgets('Reduce Transparency swaps the lens for an opaque knob',
      (tester) async {
    await tester.pumpWidget(_host(liquid: true, reduceTransparency: true));
    expect(find.byType(LiquidGlassFilter), findsNothing);
    final fill = tester
        .widget<DecoratedBox>(find.byKey(const Key('glass-slider-knob-fill')));
    expect((fill.decoration as BoxDecoration).color,
        Colors.white.withValues(alpha: 0.85));
  });

  testWidgets('without a shader the lens still paints the fallback fill',
      (tester) async {
    await tester.pumpWidget(_host(liquid: true));
    expect(find.byType(LiquidGlassFilter), findsOneWidget);
    expect(find.byKey(const Key('glass-slider-knob-fill')), findsOneWidget);
  });
}
