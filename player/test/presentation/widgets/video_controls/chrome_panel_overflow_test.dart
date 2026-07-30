// Guards the `ChromePanel` composition against real `RenderFlex` overflows
// across the widths where it actually gets tight: `chrome_panel_test.dart`
// cannot catch these — its slots are plain `SizedBox`es, which shrink under a
// tight parent instead of overflowing the way `Row`-based content
// (`SecondaryCluster`, `VolumeSurface`) does.
//
// Unlike the golden file, this runs on every platform, including Linux CI —
// it is the CI-visible half of the regression guard for this whole class of
// bug.
//
// Only 320px remains broken, and it is broken *by construction*, not
// pending: `SecondaryCluster`'s 3 buttons at their own 40px spec cost 120px
// with zero gap (the floor — already guarded by the passing-width
// assertions below), but 320px's equal-flex slot only ever offers 108px, and
// even removing 100% of `ChromePanel`'s horizontal padding (not just
// trimming it) only gets to 120px available — exactly matching, with zero
// margin for the padding itself to occupy. There is no gap/slider/padding
// lever left to pull; closing this needs either shrinking a button below
// its spec or abandoning the equal-flex centering guarantee for this one
// width, and neither is this file's call. If that changes, *move* 320px
// from `_knownBrokenWidths` to `_passingWidths` — don't just delete its
// assertion.
//
// 600px and 650px *were* asserted broken in an earlier revision of this
// file — that escalation was wrong. Both close with two more one-constant
// levers: `PanelMetrics.forWidth`'s tablet-branch width factor (0.8 -> 0.9)
// and per-tier `horizontalPadding` on `PanelMetrics` (20 -> 12 for mobile and
// tablet). See the constants' own dartdocs for the exact arithmetic.
//
// **`quality` axis:** a whole-branch review found this file's own header
// claim — "the worst case PlaybackChrome can present" — was false: it never
// wired the web-only quality button, so it missed a real Critical (a 4th
// `SecondaryCluster` button, raising its floor from 120 to 160px each side,
// overflowed <424px, 600-666px, and 900-1026px in production, clipping the
// fullscreen button on a mid-size browser window). The fix gates the button
// on `PanelMetrics.showQuality` (true only at the desktop tier, 900+ in this
// file's three-tier scheme) rather than showing it whenever the caller has
// something to wire it to — see that field's dartoc for why the tablet/
// mobile tiers cannot be widened to fit a 4th button at all. `_panel` below
// replicates that exact gate (mirroring `PlaybackChrome`'s own composition,
// not `SecondaryCluster`'s, which deliberately has no platform knowledge),
// so `quality: true` at desktop widths genuinely exercises the widened
// 0.60 -> 0.70 desktop width factor, while below that tier it exercises
// "the button was requested but the tier can't show it" — both real
// production paths.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/platform_features.dart';
import 'package:player/presentation/widgets/video_controls/chrome_panel.dart';
import 'package:player/presentation/widgets/video_controls/panel_controls.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';
import 'package:player/presentation/widgets/video_controls/video_progress_bar.dart';

/// Mirrors `PlaybackChrome`'s real composition as closely as a `Player`-free
/// test can: episode-nav wired unconditionally (as `PlaybackChrome` now does
/// — see its wiring comment), `compact` following `metrics.touchTargets`
/// (dropping seek/episode-nav to play/pause-only below the mobile
/// breakpoint), `volume` supplied whenever `metrics.showVolume`, and the
/// quality button gated on `metrics.showQuality` whenever [quality] requests
/// it (mirroring `PlaybackChrome`'s own gate — see the file header). This is
/// deliberately the *worst case* PlaybackChrome can present at a given
/// width — a caller with no adjacent episodes, or not on web, gets an
/// easier layout, not a harder one.
Widget _panel(double width, {bool quality = false}) {
  final metrics = PanelMetrics.forWidth(width);
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: ChromePanel(
          metrics: metrics,
          tier: PlayerGlassTier.full,
          transport: TransportSurface(
            isPlaying: true,
            onPreviousEpisode: () {},
            onNextEpisode: () {},
            compact: metrics.touchTargets,
          ),
          volume: metrics.showVolume
              ? VolumeSurface(
                  volume: 70,
                  onVolumeChanged: (_) {},
                  onToggleMute: () {},
                )
              : null,
          secondary: SecondaryCluster(
            subtitleTrackCount: 1,
            audioTrackCount: 2,
            onQualityTap: (quality && metrics.showQuality) ? () {} : null,
          ),
          scrubber: ProgressBarSurface(
            progress: 0.35,
            buffered: 0.55,
            touchTarget: metrics.touchTargets,
          ),
        ),
      ),
    ),
  );
}

/// Widths where `ChromePanel` renders every control at its own full,
/// specified size with no overflow. Covers: the full mobile range once the
/// transport is compact (352-599 — 352 specifically because it's the
/// narrowest width that was ever asserted-broken along the way, at the old
/// 20px padding; see `PanelMetrics.horizontalPadding`'s dartdoc), the whole
/// tablet range once `PanelMetrics`'s tablet-branch width factor and
/// per-tier padding are both in effect (600-899, including the 650px width a
/// previous revision of this file wrongly escalated), and the desktop tier
/// (900, 920, and 1600 — the last specifically to prove the `min(720, …)`
/// cap still holds once quality is wired: the widened 0.60 -> 0.70 factor
/// only matters below the point where it saturates at the cap, ~1029px, so
/// nothing about 1600px's layout should change).
const _passingWidths = <double>[
  352,
  360,
  400,
  480,
  599,
  600,
  650,
  670,
  690,
  900,
  920,
  1600,
];

/// Widths that still overflow, by construction — see the file header.
const _knownBrokenWidths = <double>[320];

/// Consumes every exception `tester` recorded, rather than just the first —
/// `TestWidgetsFlutterBinding` fails a test at teardown if *any* recorded
/// exception goes un-taken, and at some of [_knownBrokenWidths] both
/// `VolumeSurface`'s and `SecondaryCluster`'s own `Row`s overflow
/// independently in the same pump, i.e. more than one exception at once.
List<Object> _takeAllExceptions(WidgetTester tester) {
  final exceptions = <Object>[];
  for (;;) {
    final exception = tester.takeException();
    if (exception == null) break;
    exceptions.add(exception);
  }
  return exceptions;
}

void main() {
  for (final width in _passingWidths) {
    for (final quality in const [false, true]) {
      testWidgets(
        'ChromePanel at ${width}px (quality: $quality): no RenderFlex '
        'overflow, and every control renders at its own full natural size '
        '(not squeezed)',
        (tester) async {
          tester.view.physicalSize = Size(width, 600);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(_panel(width, quality: quality));
          await tester.pumpAndSettle();

          expect(_takeAllExceptions(tester), isEmpty);

          // Effective on-screen size — not `tester.getSize`, which reports
          // the pre-transform intrinsic size and would silently miss a
          // `FittedBox`-style scale-down applied by an ancestor. `getRect` is
          // transform-aware: it independently maps each corner through
          // `RenderBox.localToGlobal`, so its width reflects any ancestor
          // scaling.
          //
          // 40, not 44: `SecondaryCluster` hard-codes `size: 40` for these
          // buttons (see `panel_controls.dart`) — a deliberately smaller
          // target than `ControlButton`'s own 44px default, which is what
          // `control_button_test.dart`'s "default target meets the 44px touch
          // minimum" test measures in isolation.
          final secondaryRect = tester.getRect(
            find.byKey(SecondaryCluster.fullscreenKey),
          );
          expect(secondaryRect.width, greaterThanOrEqualTo(40));
          expect(secondaryRect.height, greaterThanOrEqualTo(40));

          final metrics = PanelMetrics.forWidth(width);
          if (metrics.showVolume) {
            final volumeRect =
                tester.getRect(find.byKey(VolumeSurface.muteKey));
            expect(volumeRect.width, greaterThanOrEqualTo(40));
            expect(volumeRect.height, greaterThanOrEqualTo(40));
          }

          // The quality button only ever renders when both requested AND
          // the tier allows it (desktop only, see PanelMetrics.showQuality)
          // — this is the exact gate PlaybackChrome applies, replicated in
          // `_panel`. At non-desktop widths `quality: true` still requests
          // it, but the tier suppresses it, same as `quality: false`.
          final showsQuality = quality && metrics.showQuality;
          expect(
            find.byKey(SecondaryCluster.qualityKey),
            showsQuality ? findsOneWidget : findsNothing,
          );
          if (showsQuality) {
            final qualityRect = tester.getRect(
              find.byKey(SecondaryCluster.qualityKey),
            );
            expect(qualityRect.width, greaterThanOrEqualTo(40));
            expect(qualityRect.height, greaterThanOrEqualTo(40));
          }
        },
      );
    }
  }

  for (final width in _knownBrokenWidths) {
    for (final quality in const [false, true]) {
      testWidgets(
        'ChromePanel at ${width}px (quality: $quality): out of budget by '
        'construction, not pending — see this file\'s header',
        (tester) async {
          tester.view.physicalSize = Size(width, 600);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(_panel(width, quality: quality));
          await tester.pumpAndSettle();

          final exceptions = _takeAllExceptions(tester);
          expect(
            exceptions,
            isNotEmpty,
            reason: 'this width was expected to still overflow; if it no '
                'longer does, move ${width}px from _knownBrokenWidths to '
                '_passingWidths above instead of loosening this assertion',
          );
          for (final exception in exceptions) {
            expect(exception.toString(), contains('RenderFlex'));
          }
        },
      );
    }
  }
}
