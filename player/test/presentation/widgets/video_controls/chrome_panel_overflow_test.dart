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
// Three widths in the matrix below (320, 600, 650) are NOT fixed by anything
// in this file's history and are asserted as *known, currently-broken*
// cases, not silently skipped: closing them would require either shrinking
// `SecondaryCluster`'s buttons below their own 40px spec (already guarded
// against by the passing-width assertions below) or a structural change to
// `ChromePanel`'s layout (equal-flex split, padding, or panel-width formula)
// that was escalated rather than freelanced. See this task's report for the
// full budget table and the exact reasoning. If you close one of these,
// *move it* from `_knownBrokenWidths` to `_passingWidths` — don't just delete
// its assertion.

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
/// breakpoint), and `volume` supplied whenever `metrics.showVolume`. This is
/// deliberately the *worst case* PlaybackChrome can present at a given
/// width — a caller with no adjacent episodes gets an easier layout, not a
/// harder one.
Widget _panel(double width) {
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
          secondary: const SecondaryCluster(
            subtitleTrackCount: 1,
            audioTrackCount: 2,
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
/// specified size with no overflow. Covers: full mobile range once the
/// transport is compact (360-599, see `TransportSurface.compact`'s dartdoc
/// for why 320-359 is not in this list), the tablet/desktop range once it
/// clears the transition band (690+), and the desktop breakpoint itself
/// (900, 920 — previously broken by 6px before `SecondaryCluster.gap` was
/// trimmed).
const _passingWidths = <double>[360, 400, 480, 599, 690, 900, 920];

/// Widths that still overflow. See the file header.
const _knownBrokenWidths = <double>[320, 600, 650];

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
    testWidgets(
      'ChromePanel at ${width}px: no RenderFlex overflow, and every '
      'control renders at its own full natural size (not squeezed)',
      (tester) async {
        tester.view.physicalSize = Size(width, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_panel(width));
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
          final volumeRect = tester.getRect(find.byKey(VolumeSurface.muteKey));
          expect(volumeRect.width, greaterThanOrEqualTo(40));
          expect(volumeRect.height, greaterThanOrEqualTo(40));
        }
      },
    );
  }

  for (final width in _knownBrokenWidths) {
    testWidgets(
      'ChromePanel at ${width}px: KNOWN, TRACKED overflow — still needs a '
      'structural fix (see this file\'s header)',
      (tester) async {
        tester.view.physicalSize = Size(width, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_panel(width));
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
