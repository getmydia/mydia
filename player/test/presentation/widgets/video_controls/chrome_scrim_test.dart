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
          const ChromeScrim(topHeight: 60, bottomHeight: 120),
        ],
      ),
    ),
  ),
);

LinearGradient _gradient(WidgetTester tester, Key key) {
  final box = tester.widget<DecoratedBox>(find.byKey(key));
  return (box.decoration as BoxDecoration).gradient! as LinearGradient;
}

void main() {
  final plateau = DepthTokens.osdTint.withValues(
    alpha: DepthTokens.osdFillOpacity,
  );
  const transparent = Color(0x00000000);

  testWidgets('bands are plateau-coloured behind each bar and transparent '
      'beyond', (tester) async {
    await tester.pumpWidget(_host());
    final origin = tester.getTopLeft(find.byType(ChromeScrim));
    final fade = ChromeScrim.fadeExtentFor(_size.height);

    final bottom = _gradient(tester, ChromeScrim.bottomKey);
    expect(bottom.colors, [transparent, plateau, plateau]);
    expect(bottom.begin, Alignment.topCenter);
    expect(bottom.end, Alignment.bottomCenter);
    final bottomRect = tester.getRect(find.byKey(ChromeScrim.bottomKey));
    expect(bottomRect.height, 120 + fade);
    expect(bottomRect.bottom, origin.dy + _size.height);

    final top = _gradient(tester, ChromeScrim.topKey);
    expect(top.colors, [plateau, plateau, transparent]);
    expect(top.begin, Alignment.topCenter);
    expect(top.end, Alignment.bottomCenter);
    final topRect = tester.getRect(find.byKey(ChromeScrim.topKey));
    expect(topRect.height, 60 + fade);
    expect(topRect.top, origin.dy);
    expect(top.stops, [0, 60 / (60 + fade), 1]);
    expect(bottom.stops, [0, fade / (120 + fade), 1]);
  });

  test('the fade is 96 px, or 12 % of the height when that is shorter', () {
    expect(ChromeScrim.maxFadeExtent, 96);
    expect(ChromeScrim.fadeExtentFor(1080), 96);
    expect(ChromeScrim.fadeExtentFor(800), 96);
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
      expect(
        tester.getRect(find.byKey(ChromeScrim.topKey)).height,
        closeTo(60 + fade, 1e-6),
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
}
