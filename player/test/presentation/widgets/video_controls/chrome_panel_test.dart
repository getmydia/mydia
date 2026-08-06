import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/platform_features.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/video_controls/chrome_panel.dart';

/// Tracks how many times it has been mounted (`initState` called), so tests
/// can prove a widget survived a rebuild rather than being torn down and
/// recreated.
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

void main() {
  group('PanelMetrics', () {
    test('desktop: capped at 720, 70% of width, 48px offset', () {
      final wide = PanelMetrics.forWidth(1600);
      expect(wide.maxWidth, 720);
      expect(wide.bottomOffset, 48);
      expect(wide.showVolume, isTrue);
      expect(wide.touchTargets, isFalse);

      // 70% of 1000 is 700, below the 720 cap.
      expect(PanelMetrics.forWidth(1000).maxWidth, 700);
    });

    test(
      'tablet: capped at 640, 90% of width, 32px offset (650px '
      'discriminates 90% from the old 80%: 0.8*650=520, 0.9*650=585, '
      'both under the 640 cap, unlike 800px which hits the cap either way)',
      () {
        final tablet = PanelMetrics.forWidth(800);
        expect(tablet.maxWidth, 640);
        expect(tablet.bottomOffset, 32);
        expect(tablet.showVolume, isTrue);

        expect(PanelMetrics.forWidth(650).maxWidth, 585);
      },
    );

    test('mobile: full width less margins, 24px offset, no volume', () {
      final mobile = PanelMetrics.forWidth(400);
      // 20, not the previous 32: the panel margin was trimmed along with
      // every other spacing constant so four secondary buttons fit at 360px.
      expect(mobile.maxWidth, 400 - 20);
      expect(mobile.bottomOffset, 24);
      expect(mobile.showVolume, isFalse);
      expect(mobile.touchTargets, isTrue);
    });

    test('boundaries land on the intended tier', () {
      expect(PanelMetrics.forWidth(900).bottomOffset, 48);
      expect(PanelMetrics.forWidth(899).bottomOffset, 32);
      expect(PanelMetrics.forWidth(600).bottomOffset, 32);
      expect(PanelMetrics.forWidth(599).bottomOffset, 24);
    });

    test('horizontalPadding: 8 on mobile/tablet, 12 on desktop', () {
      expect(PanelMetrics.forWidth(400).horizontalPadding, 8);
      expect(PanelMetrics.forWidth(599).horizontalPadding, 8);
      expect(PanelMetrics.forWidth(800).horizontalPadding, 8);
      expect(PanelMetrics.forWidth(899).horizontalPadding, 8);
      expect(PanelMetrics.forWidth(900).horizontalPadding, 12);
      expect(PanelMetrics.forWidth(1600).horizontalPadding, 12);
    });

    test('secondaryGap: 8 on desktop, 6 on tablet, 0 on mobile', () {
      // Mobile runs at the zero floor deliberately: it is what makes four
      // discrete 32px buttons fit at 360px. See PanelMetrics.showQuality.
      expect(PanelMetrics.forWidth(1600).secondaryGap, 8);
      expect(PanelMetrics.forWidth(900).secondaryGap, 8);
      expect(PanelMetrics.forWidth(800).secondaryGap, 6);
      expect(PanelMetrics.forWidth(600).secondaryGap, 6);
      expect(PanelMetrics.forWidth(400).secondaryGap, 0);
    });

    test('showQuality is true at every tier', () {
      // Was desktop-only. Compaction closed the tablet and mobile budgets;
      // see the field's dartdoc for the arithmetic.
      expect(PanelMetrics.forWidth(1600).showQuality, isTrue);
      expect(PanelMetrics.forWidth(900).showQuality, isTrue);
      expect(PanelMetrics.forWidth(800).showQuality, isTrue);
      expect(PanelMetrics.forWidth(400).showQuality, isTrue);
    });

    test('showAlwaysOnTop is desktop-only', () {
      // 600px overflows SecondaryCluster by 18px with a 5th button; see the
      // tablet branch's inline comment in chrome_panel.dart.
      expect(PanelMetrics.forWidth(1600).showAlwaysOnTop, isTrue);
      expect(PanelMetrics.forWidth(900).showAlwaysOnTop, isTrue);
      expect(PanelMetrics.forWidth(899).showAlwaysOnTop, isFalse);
      expect(PanelMetrics.forWidth(600).showAlwaysOnTop, isFalse);
      expect(PanelMetrics.forWidth(400).showAlwaysOnTop, isFalse);
    });
  });

  group('ChromePanel', () {
    Widget host(
      PanelMetrics metrics, {
      Widget? volume,
      double transportWidth = 200,
      double secondaryWidth = 120,
    }) =>
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                const Positioned.fill(child: ColoredBox(color: Colors.white)),
                ChromePanel(
                  metrics: metrics,
                  tier: PlayerGlassTier.full,
                  transport: SizedBox(
                    key: const Key('t'),
                    width: transportWidth,
                    height: 48,
                  ),
                  scrubber:
                      const SizedBox(key: Key('s'), width: 300, height: 32),
                  volume: volume,
                  secondary: SizedBox(
                    key: const Key('x'),
                    width: secondaryWidth,
                    height: 40,
                  ),
                ),
              ],
            ),
          ),
        );

    testWidgets('renders the player glass material', (tester) async {
      await tester.pumpWidget(host(PanelMetrics.forWidth(1600)));
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('renders transport and scrubber', (tester) async {
      await tester.pumpWidget(host(PanelMetrics.forWidth(1600)));
      expect(find.byKey(const Key('t')), findsOneWidget);
      expect(find.byKey(const Key('s')), findsOneWidget);
    });

    testWidgets('clips to DepthTokens.radiusPlayerPanel', (tester) async {
      await tester.pumpWidget(host(PanelMetrics.forWidth(1600)));
      final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
      expect(
        clip.borderRadius,
        const BorderRadius.all(Radius.circular(DepthTokens.radiusPlayerPanel)),
      );
    });

    testWidgets('omits the volume slot when not supplied', (tester) async {
      await tester.pumpWidget(host(PanelMetrics.forWidth(400)));
      expect(find.byKey(const Key('v')), findsNothing);
    });

    testWidgets(
      'below the mobile breakpoint, a SUPPLIED volume widget stays mounted '
      'but goes offstage/zero-size (regression: this must fail if '
      "PanelMetrics.showVolume stops gating visibility, e.g. Visibility's "
      "'visible' is ever hardcoded to true)",
      (tester) async {
        await tester.pumpWidget(
          host(
            PanelMetrics.forWidth(400),
            volume: const SizedBox(key: Key('v'), width: 110, height: 40),
          ),
        );

        // Still mounted (this is the whole point of Visibility+maintainState:
        // the previous "omits the volume slot when not supplied" test above
        // passes `volume: null`, so it can't tell a hidden-but-mounted
        // widget apart from a genuinely absent one). `skipOffstage: false` is
        // required here — Flutter's finders skip offstage elements by
        // default, so the un-qualified `find.byKey` used elsewhere in this
        // file would (incorrectly, for this specific check) also report
        // "not found" for a widget that's mounted-but-hidden by design.
        final volumeKey = find.byKey(const Key('v'), skipOffstage: false);
        expect(volumeKey, findsOneWidget);

        // ...and it's offstage specifically because of
        // PanelMetrics.showVolume (false below the mobile breakpoint), not
        // some incidental zero-sized ancestor constraint. RenderOffstage
        // still lays its child out at its natural size (per its own doc
        // comment: "the child is laid out as if it was in the tree ... but
        // without taking any room in the parent") — it's the Offstage
        // wrapper itself that reports zero size upward, not the child — so
        // the meaningful assertion is on `offstage`, not on the child's own
        // size.
        // `.first` (the closest match, not `findsOneWidget`/exactly-one):
        // Scaffold/Navigator's own internals also have an unrelated
        // `Offstage(offstage: false)` further up the tree (outside
        // ChromePanel entirely, for inactive routes/overlays), so this must
        // pick the nearest one — ChromePanel's own — rather than assume
        // there's exactly one Offstage anywhere above the key.
        final offstage = tester.widget<Offstage>(
          find.ancestor(of: volumeKey, matching: find.byType(Offstage)).first,
        );
        expect(offstage.offstage, isTrue);
      },
    );

    testWidgets('includes the volume slot when supplied', (tester) async {
      await tester.pumpWidget(
        host(
          PanelMetrics.forWidth(1600),
          volume: const SizedBox(key: Key('v'), width: 110, height: 40),
        ),
      );
      expect(find.byKey(const Key('v')), findsOneWidget);
    });

    testWidgets('never exceeds its metric max width', (tester) async {
      await tester.pumpWidget(host(PanelMetrics.forWidth(1600)));
      final width = tester.getSize(find.byType(ChromePanel)).width;
      expect(width, lessThanOrEqualTo(720));
    });

    testWidgets(
      'shrinks below its metric max width when the available width is '
      'smaller than the metric',
      (tester) async {
        // Metric says 720, but the parent only offers 300 — the panel must
        // not overflow the narrower parent.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  child: ChromePanel(
                    metrics: PanelMetrics.forWidth(1600),
                    tier: PlayerGlassTier.full,
                    transport:
                        const SizedBox(key: Key('t'), width: 60, height: 48),
                    scrubber:
                        const SizedBox(key: Key('s'), width: 60, height: 32),
                  ),
                ),
              ),
            ),
          ),
        );

        final width = tester.getSize(find.byType(ChromePanel)).width;
        expect(width, lessThanOrEqualTo(300));
      },
    );

    // Parameterized across every breakpoint tier, including mobile widths —
    // NOT just 1600px. This is a direct regression test for a real bug: an
    // earlier `ChromePanel` gave the (empty, below-mobile-breakpoint) volume
    // slot `flex: 0` instead of the equal `flex: 1` used everywhere else,
    // which measurably pinned the transport up to 187.5px off-center at some
    // mobile widths (992px, at width=599) — a defect this test, at 1600px
    // only, could never have caught, since `showVolume` is true (and both
    // sides get equal flex regardless) at that width. Testing only the
    // widest tier and assuming it generalizes down to the narrowest is
    // exactly the gap that let that regression ship.
    //
    // Transport/secondary/volume placeholder sizes here are deliberately
    // small (well under any real control's natural width) so this test
    // isolates the *geometry* question (does `ChromePanel`'s own flex layout
    // keep two equal-width slots?) from the separate *fitting* question
    // (does specific real content, e.g. `SecondaryCluster`, fit within its
    // slot at a given width?) — the latter is `chrome_panel_overflow_test
    // .dart`'s job, across a much finer-grained width matrix.
    for (final width in <double>[320, 360, 400, 480, 599, 600, 900, 1600]) {
      testWidgets(
        'the transport group is optically centered on the panel at '
        '${width}px, even when the side groups are empty or lopsided',
        (tester) async {
          final metrics = PanelMetrics.forWidth(width);

          // Empty sides: transport centre should equal panel centre.
          await tester.pumpWidget(
            host(metrics, transportWidth: 48, secondaryWidth: 40),
          );
          var panelRect = tester.getRect(find.byType(ChromePanel));
          var transportRect = tester.getRect(find.byKey(const Key('t')));
          expect(
            transportRect.center.dx,
            closeTo(panelRect.center.dx, 0.5),
            reason: 'empty sides at ${width}px',
          );

          // Lopsided sides: a wider volume cluster against a narrower
          // secondary cluster (still small enough to fit at every tested
          // width, including the narrowest mobile one). Equal-flex Expanded
          // groups should still keep the transport centred because each
          // side gets equal width regardless of its content's intrinsic
          // size.
          await tester.pumpWidget(
            host(
              metrics,
              transportWidth: 48,
              secondaryWidth: 40,
              volume: const SizedBox(key: Key('v'), width: 60, height: 40),
            ),
          );
          panelRect = tester.getRect(find.byType(ChromePanel));
          transportRect = tester.getRect(find.byKey(const Key('t')));
          expect(
            transportRect.center.dx,
            closeTo(panelRect.center.dx, 0.5),
            reason: 'lopsided sides at ${width}px',
          );
        },
      );
    }

    testWidgets(
      'renders the 12h/10v padding and the 10px row gap as real geometry',
      (tester) async {
        await tester.pumpWidget(
          host(
            PanelMetrics.forWidth(1600),
            volume: const SizedBox(key: Key('v'), width: 110, height: 40),
          ),
        );

        final panelRect = tester.getRect(find.byType(ChromePanel));
        final transportRect = tester.getRect(find.byKey(const Key('t')));
        final scrubberRect = tester.getRect(find.byKey(const Key('s')));

        // 10px vertical padding above row 1. Was 16 before compaction; see
        // `ChromePanel.verticalPadding`'s dartdoc.
        expect(transportRect.top - panelRect.top, closeTo(10, 0.5));
        // 10px gap between row 1 (48 tall) and row 2. Was 18 before
        // compaction; see `ChromePanel.rowGap`'s dartdoc.
        expect(
          scrubberRect.top - transportRect.top,
          closeTo(48 + ChromePanel.rowGap, 0.5),
        );
        // 10px vertical padding below row 2.
        expect(panelRect.bottom - scrubberRect.bottom, closeTo(10, 0.5));
        // 12px horizontal padding on the left (volume sits flush left). Was
        // 20 before compaction; see `PanelMetrics.horizontalPadding`'s
        // dartdoc.
        final volumeRect = tester.getRect(find.byKey(const Key('v')));
        expect(volumeRect.left - panelRect.left, closeTo(12, 0.5));
      },
    );

    testWidgets(
      'keeps the volume widget mounted across a showVolume breakpoint '
      'crossing (regression: VolumeCluster._lastVolume must not reset)',
      (tester) async {
        var initCount = 0;
        final probe = _InitProbe(onInit: () => initCount++);

        // Desktop: showVolume true.
        await tester
            .pumpWidget(host(PanelMetrics.forWidth(1600), volume: probe));
        expect(initCount, 1);
        expect(find.byKey(const Key('v')), findsOneWidget);

        // Cross below the mobile breakpoint: showVolume flips to false, but
        // the SAME probe widget instance is still supplied by the caller.
        await tester
            .pumpWidget(host(PanelMetrics.forWidth(400), volume: probe));
        expect(
          initCount,
          1,
          reason: 'volume widget must stay mounted (not rebuilt) when '
              'showVolume flips false, so its State (e.g. VolumeCluster\'s '
              '_lastVolume) survives',
        );

        // Cross back above: showVolume flips true again.
        await tester
            .pumpWidget(host(PanelMetrics.forWidth(1600), volume: probe));
        expect(initCount, 1);
      },
    );
  });
}
