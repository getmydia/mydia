import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/presentation/widgets/video_controls/chrome_bottom_bar.dart';

class _InitProbe extends StatefulWidget {
  const _InitProbe({required this.onInit});

  final VoidCallback onInit;

  @override
  State<_InitProbe> createState() => _InitProbeState();
}

class _InitProbeState extends State<_InitProbe> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) =>
      const SizedBox(key: Key('v'), width: 110, height: 40);
}

const _secondary = SizedBox(key: Key('x'), width: 120, height: 40);

Widget _host(
  ChromeMetrics metrics, {
  Widget? volume,
  double transportWidth = 48,
  Widget secondary = _secondary,
}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: ChromeBottomBar(
        metrics: metrics,
        timecodes: const SizedBox(key: Key('tc')),
        scrubber: const SizedBox(key: Key('s')),
        transport: SizedBox(
          key: const Key('t'),
          width: transportWidth,
          height: 44,
        ),
        volume: volume,
        secondary: secondary,
      ),
    ),
  ),
);

void _setView(WidgetTester tester, double width, [double height = 600]) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('ChromeMetrics.resolve', () {
    // Literal expected values, copied from the retired PanelMetrics tiers.
    // (width, showVolume, touchTargets, compactTransport, showQuality,
    //  showAlwaysOnTop, secondaryGap, horizontalPadding)
    const table = <(double, bool, bool, bool, bool, bool, double, double)>[
      (320, false, true, true, true, false, 0, 16),
      (599, false, true, true, true, false, 0, 16),
      (600, true, false, false, true, false, 6, 24),
      (899, true, false, false, true, false, 6, 24),
      (900, true, false, false, true, true, 8, 24),
      (1600, true, false, false, true, true, 8, 24),
    ];
    for (final row in table) {
      test('tier flags at ${row.$1}px', () {
        final m = ChromeMetrics.forWidth(row.$1);
        expect(m.showVolume, row.$2);
        expect(m.touchTargets, row.$3);
        expect(m.compactTransport, row.$4);
        expect(m.showQuality, row.$5);
        expect(m.showAlwaysOnTop, row.$6);
        expect(m.secondaryGap, row.$7);
        expect(m.horizontalPadding, row.$8);
      });
    }

    test('touchPrimary enlarges targets without compacting the transport', () {
      final m = ChromeMetrics.resolve(width: 800, touchPrimary: true);
      expect(m.touchTargets, isTrue);
      expect(m.compactTransport, isFalse);
      expect(m.showVolume, isTrue);
    });

    test('cornerInsetBottom is barHeight plus the gap', () {
      final m = ChromeMetrics.forWidth(1280);
      expect(m.cornerInsetBottom, m.barHeight + ChromeMetrics.cornerGap);
    });
  });

  group('ChromeBottomBar', () {
    for (final width in <double>[320, 600, 1280]) {
      for (final touch in [true, false]) {
        testWidgets('rendered height equals ChromeMetrics.barHeight at '
            '${width}px (touch: $touch)', (tester) async {
          _setView(tester, width);
          final metrics = ChromeMetrics.resolve(
            width: width,
            touchPrimary: touch,
          );
          await tester.pumpWidget(_host(metrics));
          expect(
            tester.getSize(find.byType(ChromeBottomBar)).height,
            closeTo(metrics.barHeight, 0.01),
          );
        });
      }
    }

    for (final width in <double>[320, 400, 1280]) {
      testWidgets('transport is centred on the bar at ${width}px, with and '
          'without volume', (tester) async {
        _setView(tester, width);
        final metrics = ChromeMetrics.forWidth(width);
        for (final volume in <Widget?>[
          null,
          const SizedBox(key: Key('v'), width: 60, height: 40),
        ]) {
          await tester.pumpWidget(_host(metrics, volume: volume));
          expect(
            tester.getRect(find.byKey(const Key('t'))).center.dx,
            closeTo(
              tester.getRect(find.byType(ChromeBottomBar)).center.dx,
              0.5,
            ),
          );
        }
      });
    }

    testWidgets('secondary sits in an osdPill', (tester) async {
      await tester.pumpWidget(_host(ChromeMetrics.forWidth(1280)));
      expect(
        find.descendant(
          of: find.byKey(ChromeBottomBar.secondaryPillKey),
          matching: find.byWidget(_secondary),
        ),
        findsOneWidget,
      );
    });

    testWidgets('omits the volume slot when not supplied', (tester) async {
      await tester.pumpWidget(_host(ChromeMetrics.forWidth(1280)));
      expect(find.byKey(const Key('v')), findsNothing);
    });

    testWidgets('a supplied volume stays mounted but offstage when '
        'showVolume is false', (tester) async {
      await tester.pumpWidget(
        _host(
          ChromeMetrics.forWidth(400),
          volume: const SizedBox(key: Key('v'), width: 110, height: 40),
        ),
      );
      final volumeKey = find.byKey(const Key('v'), skipOffstage: false);
      expect(volumeKey, findsOneWidget);
      final offstage = tester.widget<Offstage>(
        find.ancestor(of: volumeKey, matching: find.byType(Offstage)).first,
      );
      expect(offstage.offstage, isTrue);
    });

    testWidgets('volume state survives a showVolume flip', (tester) async {
      var initCount = 0;
      final probe = _InitProbe(onInit: () => initCount++);

      await tester.pumpWidget(
        _host(ChromeMetrics.forWidth(1600), volume: probe),
      );
      expect(initCount, 1);
      await tester.pumpWidget(
        _host(ChromeMetrics.forWidth(400), volume: probe),
      );
      expect(initCount, 1);
      await tester.pumpWidget(
        _host(ChromeMetrics.forWidth(1600), volume: probe),
      );
      expect(initCount, 1);
    });

    testWidgets('corner widget clears the bar at 600 px', (tester) async {
      _setView(tester, 600, 400);
      final metrics = ChromeMetrics.forWidth(600);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ChromeBottomBar(
                    metrics: metrics,
                    timecodes: const SizedBox(),
                    scrubber: const SizedBox(),
                    secondary: _secondary,
                  ),
                ),
                Positioned(
                  right: ChromeMetrics.cornerInsetRight,
                  bottom: metrics.cornerInsetBottom,
                  child: const SizedBox(
                    key: Key('corner'),
                    width: 120,
                    height: 48,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final bar = tester.getRect(find.byType(ChromeBottomBar));
      final corner = tester.getRect(find.byKey(const Key('corner')));
      expect(bar.overlaps(corner), isFalse);
      expect(bar.top - corner.bottom, closeTo(ChromeMetrics.cornerGap, 0.5));
    });
  });
}
