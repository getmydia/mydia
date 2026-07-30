// Guards the mobile-width `ChromePanel` composition against the real
// `RenderFlex` overflow found while building the (macOS-only, CI-skipped)
// panel goldens: `chrome_panel_test.dart` cannot catch this because its
// slots are plain `SizedBox`es, which shrink under a tight parent instead of
// overflowing the way a `Row`-based widget (`SecondaryCluster`) does.
//
// Unlike the golden file, this runs on every platform, including Linux CI —
// it is the CI-visible half of the regression guard for that bug.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/platform_features.dart';
import 'package:player/presentation/widgets/video_controls/chrome_panel.dart';
import 'package:player/presentation/widgets/video_controls/panel_controls.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';
import 'package:player/presentation/widgets/video_controls/video_progress_bar.dart';

Widget _panel(double width) {
  final metrics = PanelMetrics.forWidth(width);
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: ChromePanel(
          metrics: metrics,
          tier: PlayerGlassTier.full,
          // No episode-nav callbacks: this mirrors what `PlaybackChrome`
          // actually composes at the mobile breakpoint (`metrics.
          // touchTargets`) after dropping them there — see the comment on
          // that wiring in `playback_chrome.dart`. `metrics.showVolume` is
          // false in this width range, so `volume` is omitted here exactly
          // as real callers are told to (`ChromePanel.volume`'s dartdoc
          // still wants it supplied unconditionally in a real app, but
          // that's for `Visibility`-driven state preservation across a
          // breakpoint crossing, not relevant to a single fixed-width test).
          transport: const TransportSurface(isPlaying: true),
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

void main() {
  for (final width in <double>[360, 400]) {
    testWidgets(
      'ChromePanel at ${width}px: no RenderFlex overflow, and the '
      'secondary cluster renders at its full natural size (not squeezed)',
      (tester) async {
        tester.view.physicalSize = Size(width, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_panel(width));
        await tester.pumpAndSettle();

        // No overflow (or any other) exception recorded during layout/paint.
        expect(tester.takeException(), isNull);

        // The fullscreen button's *effective* on-screen size — not
        // `tester.getSize`, which reports the pre-transform intrinsic size
        // and would silently miss a `FittedBox`-style scale-down applied by
        // an ancestor. `getRect` is transform-aware: it independently maps
        // each corner through `RenderBox.localToGlobal`, so its width
        // reflects any ancestor scaling.
        //
        // 40, not 44: `SecondaryCluster` hard-codes `size: 40` for these
        // buttons (see `panel_controls.dart`) — a deliberately smaller
        // target than `ControlButton`'s own 44px default, which is what
        // `control_button_test.dart`'s "default target meets the 44px touch
        // minimum" test measures in isolation. The guard here is that the
        // button renders at *its own* specified size, neither overflowed
        // nor silently shrunk further by an ancestor.
        final rect = tester.getRect(
          find.byKey(SecondaryCluster.fullscreenKey),
        );
        expect(rect.width, greaterThanOrEqualTo(40));
        expect(rect.height, greaterThanOrEqualTo(40));
      },
    );
  }
}
