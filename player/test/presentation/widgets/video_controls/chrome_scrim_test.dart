import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/video_controls/chrome_scrim.dart';

const _size = Size(800, 450);

Widget _host({Widget? behind}) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: _size.width,
      height: _size.height,
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

    final bottom = _gradient(tester, ChromeScrim.bottomKey);
    expect(bottom.colors, [transparent, plateau, plateau]);
    expect(bottom.begin, Alignment.topCenter);
    expect(bottom.end, Alignment.bottomCenter);
    final bottomRect = tester.getRect(find.byKey(ChromeScrim.bottomKey));
    expect(bottomRect.height, 120 + ChromeScrim.fadeExtent);
    expect(bottomRect.bottom, origin.dy + _size.height);

    final top = _gradient(tester, ChromeScrim.topKey);
    expect(top.colors, [plateau, plateau, transparent]);
    expect(top.begin, Alignment.topCenter);
    expect(top.end, Alignment.bottomCenter);
    final topRect = tester.getRect(find.byKey(ChromeScrim.topKey));
    expect(topRect.height, 60 + ChromeScrim.fadeExtent);
    expect(topRect.top, origin.dy);
    expect(top.stops, [0, 60 / (60 + ChromeScrim.fadeExtent), 1]);
    expect(bottom.stops, [
      0,
      ChromeScrim.fadeExtent / (120 + ChromeScrim.fadeExtent),
      1,
    ]);
  });

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
