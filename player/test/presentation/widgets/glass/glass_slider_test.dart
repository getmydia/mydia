import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool enabled = true,
  TextDirection textDirection = TextDirection.ltr,
}) =>
    MaterialApp(
      theme: AppTheme.build(Palettes.projectionBooth, liquid: liquid),
      home: Directionality(
        textDirection: textDirection,
        child: GlassAccessibilityScope(
          value: GlassAccessibility(reduceTransparency: reduceTransparency),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: _width,
                child: GlassSlider(
                  value: value,
                  onChanged: enabled ? (onChanged ?? (_) {}) : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );

double _knobCentreX(WidgetTester tester) =>
    tester.getCenter(find.byType(LiquidGlassFilter)).dx;

/// A zero size thumb that records where Material asks it to paint, in global
/// coordinates.
class _RecordingThumb extends SliderComponentShape {
  Offset? center;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size.zero;

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    this.center = parentBox.localToGlobal(center);
  }
}

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
    // A rounded track keeps the thumb a track radius inside each end.
    final trackHeight = tester
        .widget<SliderTheme>(find.byType(SliderTheme).last)
        .data
        .trackHeight!;
    expect(right - left,
        closeTo(_width - LiquidGeometry.sliderKnobWidth - trackHeight, 1));
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

  testWidgets('in rtl the knob mirrors: value 0 sits right of centre',
      (tester) async {
    await tester.pumpWidget(
        _host(liquid: true, value: 0, textDirection: TextDirection.rtl));
    final centre = tester.getCenter(find.byType(GlassSlider)).dx;
    expect(_knobCentreX(tester), greaterThan(centre));
    await tester.pumpWidget(
        _host(liquid: true, value: 1, textDirection: TextDirection.rtl));
    expect(_knobCentreX(tester), lessThan(centre));
  });

  testWidgets('a discrete knob sits on the thumb centre at each division',
      (tester) async {
    var value = 10.0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(Palettes.projectionBooth, liquid: true),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: _width,
            child: StatefulBuilder(
              builder: (context, setState) => GlassSlider(
                value: value,
                min: 10,
                max: 50,
                divisions: 4,
                onChanged: (v) => setState(() => value = v),
              ),
            ),
          ),
        ),
      ),
    ));
    final box = tester.getTopLeft(find.byType(GlassSlider));
    final trackStart = LiquidGeometry.sliderKnobWidth / 2;
    final trackWidth = _width - LiquidGeometry.sliderKnobWidth;
    final trackHeight = tester
        .widget<SliderTheme>(find.byType(SliderTheme).last)
        .data
        .trackHeight!;
    for (var i = 0; i <= 4; i++) {
      final t = i / 4;
      // Hit testing excludes the far edge, so land a hair inside it.
      await tester.tapAt(
          Offset(box.dx + trackStart + t * trackWidth - 0.1, box.dy + 12));
      await tester.pumpAndSettle();
      expect(value, 10 + 10.0 * i);
      final expected = box.dx +
          trackStart +
          t * (trackWidth - trackHeight) +
          trackHeight / 2;
      expect(_knobCentreX(tester), closeTo(expected, 0.5));
    }
  });

  testWidgets('keeps the knob size in an unbounded-height parent',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(Palettes.projectionBooth, liquid: true),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              SizedBox(
                width: _width,
                child: GlassSlider(value: 0.5, onChanged: (_) {}),
              ),
            ],
          ),
        ),
      ),
    ));
    expect(tester.getSize(find.byType(GlassSlider)).height,
        greaterThanOrEqualTo(LiquidGeometry.sliderKnobHeight));
    expect(
        tester.getSize(find.byType(LiquidGlassFilter)),
        const Size(
            LiquidGeometry.sliderKnobWidth, LiquidGeometry.sliderKnobHeight));
  });

  testWidgets('keyboard focus rings the knob', (tester) async {
    await tester.pumpWidget(_host(liquid: true));
    expect(find.byKey(const Key('glass-slider-focus-ring')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('glass-slider-focus-ring')), findsOneWidget);
  });

  testWidgets('the knob is excluded from semantics', (tester) async {
    await tester.pumpWidget(_host(liquid: true));
    expect(
        find.ancestor(
            of: find.byType(LiquidGlassFilter),
            matching: find.byType(ExcludeSemantics)),
        findsOneWidget);
  });

  for (final discrete in [false, true]) {
    testWidgets(
        'the knob centre equals the thumb centre Material paints '
        '(${discrete ? 'discrete' : 'continuous'})', (tester) async {
      final thumb = _RecordingThumb();
      for (final t in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.build(Palettes.projectionBooth, liquid: true),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: _width,
                child: GlassSlider(
                  value: discrete ? 10 + 40 * t : t,
                  min: discrete ? 10 : 0,
                  max: discrete ? 50 : 1,
                  divisions: discrete ? 4 : null,
                  onChanged: (_) {},
                  debugThumbShape: thumb,
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(thumb.center, isNotNull);
        expect(_knobCentreX(tester), closeTo(thumb.center!.dx, 0.5),
            reason: 't=$t');
      }
    });
  }

  testWidgets('a disabled knob is half opaque and does not scale',
      (tester) async {
    await tester.pumpWidget(_host(liquid: true, enabled: false));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0.5);
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1.0);
    await tester.pumpWidget(_host(liquid: true));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1.0);
  });

  testWidgets('an unbounded width does not throw or place the knob at infinity',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(Palettes.projectionBooth, liquid: true),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              height: 48,
              child: GlassSlider(value: 0.5, onChanged: (_) {}),
            ),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(GlassSlider)).width.isFinite, isTrue);
  });
}
