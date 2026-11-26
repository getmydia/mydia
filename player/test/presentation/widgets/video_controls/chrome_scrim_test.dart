import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/depth_tokens.dart';
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

  test('the fade is 160 px, or 12 % of the height when that is shorter', () {
    expect(ChromeScrim.maxFadeExtent, 160);
    expect(ChromeScrim.fadeExtentFor(1400), 160);
    expect(ChromeScrim.fadeExtentFor(1080), closeTo(129.6, 1e-9));
    expect(ChromeScrim.fadeExtentFor(1000), closeTo(120, 1e-9));
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

  group('alphaAt', () {
    const cases = [
      (height: 1080.0, title: 52.0, plateau: 140.0),
      (height: 800.0, title: 52.0, plateau: 140.0),
      (height: 350.0, title: 38.0, plateau: 110.0),
      (height: 2160.0, title: 68.0, plateau: 200.0),
    ];

    for (final c in cases) {
      test(
        'one non-increasing curve at ${c.height} with a ${c.title} title',
        () {
          double at(double y) => ChromeScrim.alphaAt(
            y,
            plateau: c.plateau,
            titleHeight: c.title,
            height: c.height,
          );
          final top =
              c.plateau +
              ChromeScrim.extentAbovePlateau(
                height: c.height,
                titleHeight: c.title,
              );
          var previous = at(0);
          expect(previous, DepthTokens.osdFillOpacity);
          for (var y = 2.0; y <= c.height; y += 2) {
            final a = at(y);
            expect(a, lessThanOrEqualTo(previous + 1e-12), reason: 'y=$y');
            previous = a;
          }
          expect(at(c.plateau), DepthTokens.osdFillOpacity);
          expect(
            at(c.plateau + c.title),
            greaterThanOrEqualTo(DepthTokens.osdTitleScrimOpacity - 1e-9),
          );
          expect(at(top), 0);
          expect(at(top + 10), 0);
        },
      );
    }

    test('without a title it is today\'s band: plateau, then the fade', () {
      const height = 800.0;
      final fade = ChromeScrim.fadeExtentFor(height);
      expect(
        ChromeScrim.extentAbovePlateau(height: height, titleHeight: 0),
        fade,
      );
      double at(double y) =>
          ChromeScrim.alphaAt(y, plateau: 120, titleHeight: 0, height: height);
      expect(at(120), DepthTokens.osdFillOpacity);
      expect(at(120 + fade), 0);
      expect(
        at(120 + fade / 2),
        closeTo(DepthTokens.osdFillOpacity * 0.5, 1e-9),
      );
    });

    test('the ease fraction lands on the title opacity', () {
      final t = ChromeScrim.titleEaseFraction;
      expect(
        DepthTokens.osdFillOpacity * (1 - Curves.easeInOut.transform(t)),
        closeTo(DepthTokens.osdTitleScrimOpacity, 5e-3),
      );
    });

    testWidgets('the painted gradient samples alphaAt at every stop', (
      tester,
    ) async {
      const plateauHeight = 140.0;
      const titleHeight = 52.0;
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: SizedBox(
              width: 800,
              height: 450,
              child: Stack(
                children: [
                  ChromeScrim(
                    bottomHeight: plateauHeight,
                    titleHeight: titleHeight,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final gradient = _gradient(tester);
      final total = tester.getRect(find.byKey(ChromeScrim.bottomKey)).height;
      expect(gradient.colors.length, ChromeScrim.fadeSteps + 2);
      for (var i = 0; i < gradient.colors.length; i++) {
        final fromBottom = total * (1 - gradient.stops![i]);
        expect(
          gradient.colors[i].a,
          closeTo(
            ChromeScrim.alphaAt(
              fromBottom,
              plateau: plateauHeight,
              titleHeight: titleHeight,
              height: 450,
            ),
            1e-6,
          ),
          reason: 'stop $i',
        );
      }
    });
  });
}
