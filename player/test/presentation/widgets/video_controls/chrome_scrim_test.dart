import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/glass/osd_glass.dart';
import 'package:player/presentation/widgets/video_controls/chrome_scrim.dart';

const _size = Size(800, 450);

Widget _host({Widget? behind, Size size = _size}) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          if (behind != null) Positioned.fill(child: behind),
          const ChromeScrim(bottomHeight: 120),
        ],
      ),
    ),
  ),
);

LinearGradient _gradient(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(find.byKey(ChromeScrim.bottomKey));
  return (box.decoration as BoxDecoration).gradient! as LinearGradient;
}

void main() {
  final plateau = DepthTokens.osdTint.withValues(
    alpha: DepthTokens.osdFillOpacity,
  );

  testWidgets('one band at the bottom, solid behind the bar and transparent '
      'beyond it', (tester) async {
    await tester.pumpWidget(_host());
    final origin = tester.getTopLeft(find.byType(ChromeScrim));
    final fade = ChromeScrim.fadeExtentFor(_size.height);

    final gradient = _gradient(tester);
    expect(gradient.begin, Alignment.topCenter);
    expect(gradient.end, Alignment.bottomCenter);
    expect(gradient.colors.first.a, 0);
    expect(gradient.colors.last, plateau);

    final rect = tester.getRect(find.byKey(ChromeScrim.bottomKey));
    expect(rect.height, 120 + fade);
    expect(rect.bottom, origin.dy + _size.height);

    // The fade ends exactly where the plateau begins.
    final stops = gradient.stops!;
    final plateauStart = fade / (120 + fade);
    expect(stops.last, 1);
    expect(stops[stops.length - 2], closeTo(plateauStart, 1e-9));
    expect(gradient.colors[stops.length - 2], plateau);
  });

  testWidgets('no band at the top: the top bar floats in its own pills', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    expect(find.byType(DecoratedBox), findsOneWidget);
  });

  testWidgets('the fade eases in and out instead of ramping linearly', (
    tester,
  ) async {
    // A linear ramp into a solid plateau leaves a visible shelf where the
    // two meet. An eased ramp starts and ends with a near-zero slope.
    await tester.pumpWidget(_host());
    final gradient = _gradient(tester);
    final stops = gradient.stops!;
    final alphas = gradient.colors.map((c) => c.a).toList();
    final fadeEnd = stops.length - 2;

    expect(fadeEnd, greaterThanOrEqualTo(ChromeScrim.fadeSteps));
    for (var i = 1; i <= fadeEnd; i++) {
      expect(alphas[i], greaterThanOrEqualTo(alphas[i - 1]));
    }
    double slope(int i) =>
        (alphas[i + 1] - alphas[i]) / (stops[i + 1] - stops[i]);
    final linearSlope = plateau.a / stops[fadeEnd];
    expect(slope(0), lessThan(linearSlope * 0.5));
    expect(slope(fadeEnd - 1), lessThan(linearSlope * 0.5));
    expect(slope(fadeEnd ~/ 2), greaterThan(linearSlope));
  });

  test('the fade is 120 px, or 12 % of the height when that is shorter', () {
    expect(ChromeScrim.maxFadeExtent, 120);
    expect(ChromeScrim.fadeExtentFor(1080), 120);
    expect(ChromeScrim.fadeExtentFor(1000), 120);
    expect(ChromeScrim.fadeExtentFor(390), closeTo(46.8, 1e-9));
    expect(ChromeScrim.fadeExtentFor(320), closeTo(38.4, 1e-9));
  });

  for (final size in const [Size(844, 390), Size(1280, 900)]) {
    testWidgets('fade length follows the scrim height at $size', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2000, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_host(size: size));

      final fade = ChromeScrim.fadeExtentFor(size.height);
      expect(
        tester.getRect(find.byKey(ChromeScrim.bottomKey)).height,
        closeTo(120 + fade, 1e-6),
      );
    });
  }

  testWidgets('ignores pointers', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(behind: GestureDetector(onTap: () => taps++)),
    );
    final origin = tester.getTopLeft(find.byType(ChromeScrim));

    await tester.tapAt(origin + Offset(_size.width / 2, _size.height / 2));
    await tester.tapAt(origin + const Offset(10, 440));
    expect(taps, 2);
  });

  for (final entry in const {
    'sampled': (TargetPlatform.iOS, false),
    'dry': (TargetPlatform.macOS, true),
  }.entries) {
    testWidgets('${entry.key} glass: pure gradient, no plateau', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = entry.value.$1;
      LiquidGlassSupport.debugOverride = true;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(Palettes.projectionBooth, liquid: true),
            home: OsdGlassScope(
              surfaceOutput: entry.value.$2,
              child: Center(
                child: SizedBox(
                  width: _size.width,
                  height: _size.height,
                  child: const Stack(
                    children: [ChromeScrim(bottomHeight: 120)],
                  ),
                ),
              ),
            ),
          ),
        );
        final edge = DepthTokens.osdTint.withValues(
          alpha: DepthTokens.osdLiquidScrimOpacity,
        );
        final fade = ChromeScrim.fadeExtentFor(_size.height);

        final bottom = _gradient(tester);
        expect(bottom.colors, [const Color(0x00000000), edge]);
        expect(bottom.stops, [0, 1]);
        expect(
          tester.getRect(find.byKey(ChromeScrim.bottomKey)).height,
          120 + fade,
        );
        expect(DepthTokens.osdLiquidScrimOpacity, 0.35);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        LiquidGlassSupport.debugOverride = null;
      }
    });
  }
}
