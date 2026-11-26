import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
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
  bool controlsFirst = false,
}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: ChromeBottomBar(
        metrics: metrics,
        elapsed: const Text('00:05', key: Key('e')),
        remaining: const Text('-24:50', key: Key('r')),
        scrubber: const SizedBox(key: Key('s')),
        transport: SizedBox(
          key: const Key('t'),
          width: transportWidth,
          height: 44,
        ),
        volume: volume,
        secondary: secondary,
        controlsFirst: controlsFirst,
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
    // Literal expected values, copied from the retired panel tiers.
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

    test('compactTouch is a touch phone, by its shortest side', () {
      // (width, height, touchPrimary, compactTouch)
      const cases = <(double, double, bool, bool)>[
        (760, 350, true, true), // landscape phone
        (390, 844, true, true), // portrait phone
        (1280, 720, true, false), // touch tablet
        (760, 350, false, false), // short desktop window
        (400, 300, false, false),
      ];
      for (final c in cases) {
        expect(
          ChromeMetrics.resolve(
            width: c.$1,
            height: c.$2,
            touchPrimary: c.$3,
          ).compactTouch,
          c.$4,
          reason: '${c.$1}x${c.$2} touch: ${c.$3}',
        );
      }
    });

    test('compactTouch drops volume, tightens padding and the bar', () {
      final m = ChromeMetrics.resolve(
        width: 760,
        height: 350,
        touchPrimary: true,
      );
      expect(m.showVolume, isFalse);
      expect(m.horizontalPadding, 12);
      expect(m.barHeight, 56);
      expect(
        m.barHeight,
        ChromeBottomBar.heightFor(touchTargets: true, compactTouch: true),
      );
    });

    test('touchPrimary enlarges targets without compacting the transport', () {
      final m = ChromeMetrics.resolve(
        width: 800,
        height: 800,
        touchPrimary: true,
      );
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
        final metrics = ChromeMetrics.resolve(
          width: width,
          height: 800,
          touchPrimary: touch,
        );
        // A 320 px touch viewport is a phone, which draws
        // CompactChromeBottomBar; that bar has its own group below.
        if (metrics.compactTouch) continue;
        testWidgets('rendered height equals ChromeMetrics.barHeight at '
            '${width}px (touch: $touch)', (tester) async {
          _setView(tester, width);
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

    testWidgets('no group carries a pill: the scrim is the backing', (
      tester,
    ) async {
      await tester.pumpWidget(_host(ChromeMetrics.forWidth(1280)));
      expect(
        find.descendant(
          of: find.byType(ChromeBottomBar),
          matching: find.byType(GlassSurface),
        ),
        findsNothing,
      );
    });

    testWidgets('timecodes sit either side of the scrubber, on its line', (
      tester,
    ) async {
      final metrics = ChromeMetrics.forWidth(1280);
      await tester.pumpWidget(_host(metrics));
      final elapsed = tester.getRect(find.byKey(const Key('e')));
      final scrubber = tester.getRect(find.byKey(const Key('s')));
      final remaining = tester.getRect(find.byKey(const Key('r')));
      final bar = tester.getRect(find.byType(ChromeBottomBar));

      expect(elapsed.left, closeTo(bar.left + metrics.horizontalPadding, 0.5));
      expect(scrubber.left - elapsed.right, ChromeBottomBar.timecodeGap);
      expect(remaining.left - scrubber.right, ChromeBottomBar.timecodeGap);
      expect(
        remaining.right,
        closeTo(bar.right - metrics.horizontalPadding, 0.5),
      );
      expect(elapsed.center.dy, closeTo(scrubber.center.dy, 0.5));
      expect(remaining.center.dy, closeTo(scrubber.center.dy, 0.5));
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

    for (final controlsFirst in [false, true]) {
      testWidgets('row order and height with controlsFirst: $controlsFirst', (
        tester,
      ) async {
        final metrics = ChromeMetrics.forWidth(1280);
        await tester.pumpWidget(_host(metrics, controlsFirst: controlsFirst));

        final scrubber = tester.getRect(find.byKey(const Key('s')));
        final controls = tester.getRect(find.byKey(const Key('t')));
        if (controlsFirst) {
          expect(controls.bottom, lessThanOrEqualTo(scrubber.top));
        } else {
          expect(controls.top, greaterThanOrEqualTo(scrubber.bottom));
        }
        expect(
          tester.getSize(find.byType(ChromeBottomBar)).height,
          closeTo(metrics.barHeight, 0.5),
        );
      });
    }

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
                    elapsed: const SizedBox(),
                    remaining: const SizedBox(),
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

  group('CompactChromeBottomBar', () {
    Widget compactHost(ChromeMetrics metrics) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: CompactChromeBottomBar(
            metrics: metrics,
            elapsed: const Text('17:03', key: Key('e')),
            remaining: const Text('-06:56', key: Key('r')),
            scrubber: const SizedBox(key: Key('s')),
          ),
        ),
      ),
    );

    for (final size in const <Size>[
      Size(320, 568),
      Size(568, 320),
      Size(760, 350),
      Size(932, 430),
    ]) {
      testWidgets('one row of barHeight at $size', (tester) async {
        _setView(tester, size.width, size.height);
        final metrics = ChromeMetrics.resolve(
          width: size.width,
          height: size.height,
          touchPrimary: true,
        );
        expect(metrics.compactTouch, isTrue);
        await tester.pumpWidget(compactHost(metrics));

        expect(
          tester.getSize(find.byType(CompactChromeBottomBar)).height,
          closeTo(metrics.barHeight, 0.01),
        );
        final elapsed = tester.getRect(find.byKey(const Key('e')));
        final scrubber = tester.getRect(find.byKey(const Key('s')));
        final remaining = tester.getRect(find.byKey(const Key('r')));
        // Elapsed | scrubber | remaining, on one line.
        expect(elapsed.right, lessThanOrEqualTo(scrubber.left));
        expect(scrubber.right, lessThanOrEqualTo(remaining.left));
        expect(elapsed.center.dy, closeTo(scrubber.center.dy, 0.5));
        expect(remaining.center.dy, closeTo(scrubber.center.dy, 0.5));
        // The scrubber takes every pixel the timecodes leave.
        expect(
          scrubber.width,
          closeTo(
            size.width -
                2 * metrics.horizontalPadding -
                2 * CompactChromeBottomBar.timecodeGap -
                elapsed.width -
                remaining.width,
            0.5,
          ),
        );
      });
    }
  });
}
