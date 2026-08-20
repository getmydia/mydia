import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/platform_features.dart';
import 'package:player/presentation/widgets/video_controls/chrome_panel.dart';
import 'package:player/presentation/widgets/video_controls/panel_controls.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';
import 'package:player/presentation/widgets/video_controls/video_progress_bar.dart';

/// Mirrors `PlaybackChrome`'s real composition, the same way
/// `chrome_panel_overflow_test.dart`'s own `_panel` helper does (see that
/// file for the fuller rationale on each choice below): episode nav wired
/// unconditionally, `compact` following `metrics.compactTransport`, volume
/// shown whenever `metrics.showVolume`, and the quality button always
/// present (every tier's `showQuality` is true now). This is the actual
/// layout [PanelMetrics.cornerInsetBottom] has to clear — measuring against
/// anything narrower (e.g. a hand-picked subset of controls) would
/// understate the panel's real height.
Widget _panel(double width) {
  final metrics = PanelMetrics.forWidth(width);
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: ChromePanel(
          metrics: metrics,
          // Forced so measurements do not vary with the host platform.
          tier: PlayerGlassTier.full,
          transport: TransportSurface(
            isPlaying: true,
            onPreviousEpisode: () {},
            onNextEpisode: () {},
            compact: metrics.compactTransport,
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
            gap: metrics.secondaryGap,
            onQualityTap: () {},
            onFullscreenTap: () {},
            onAlwaysOnTopTap: metrics.showAlwaysOnTop ? () {} : null,
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
  /// The widths that matter: the mobile floor, either side of each
  /// breakpoint, and a wide desktop window.
  const widths = <double>[360, 599, 600, 899, 900, 1440];

  group('PanelMetrics.cornerInsetBottom', () {
    test('clears the panel at every tier', () {
      for (final width in widths) {
        final metrics = PanelMetrics.forWidth(width);
        expect(
          metrics.cornerInsetBottom,
          greaterThan(metrics.bottomOffset),
          reason: 'a corner overlay at ${width}px would sit inside the panel',
        );
      }
    });

    testWidgets(
        'leaves at least a 12px gap above the panel\'s real, measured '
        'height at every tier — not a second copy of `_panelHeight`\'s own '
        'arithmetic, which would drift in lockstep with a production bug '
        'and never catch it', (tester) async {
      for (final width in widths) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_panel(width));
        await tester.pumpAndSettle();

        // `getRect`, not `getSize`: transform-aware, so it would still be
        // correct if an ancestor ever scaled the panel down (see
        // `chrome_panel_overflow_test.dart` for the same reasoning applied
        // to width).
        final measuredHeight = tester.getRect(find.byType(ChromePanel)).height;
        final metrics = PanelMetrics.forWidth(width);
        final clearance = metrics.cornerInsetBottom - metrics.bottomOffset;

        expect(
          clearance,
          greaterThanOrEqualTo(measuredHeight + 12),
          reason: 'insufficient clearance at ${width}px: the panel measured '
              '${measuredHeight}px tall but the corner inset only left '
              '${clearance}px above it',
        );
      }
    });

    test('rises with the panel offset across tiers', () {
      // Desktop sits the panel highest, so its corner inset is highest too.
      expect(
        PanelMetrics.forWidth(1440).cornerInsetBottom,
        greaterThan(PanelMetrics.forWidth(360).cornerInsetBottom),
      );
    });
  });
}
