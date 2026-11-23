// Guards the `ChromeBottomBar` composition against real `RenderFlex`
// overflows with the real clusters. `chrome_bottom_bar_test.dart` uses plain
// `SizedBox` slots, which shrink under a tight parent instead of overflowing
// the way `Row`-based content does.

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/widgets/video_controls/chrome_bottom_bar.dart';
import 'package:player/presentation/widgets/video_controls/panel_controls.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';
import 'package:player/presentation/widgets/video_controls/video_progress_bar.dart';

Widget _bar(double width, {bool quality = true, bool alwaysOnTop = false}) {
  final metrics = ChromeMetrics.forWidth(width);
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: ChromeBottomBar(
          metrics: metrics,
          timecodes: const SizedBox(),
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
            audioTrackCount: 2,
            onSubtitleTap: () {},
            gap: metrics.secondaryGap,
            onQualityTap: quality ? () {} : null,
            onFullscreenTap: () {},
            onAlwaysOnTopTap: alwaysOnTop ? () {} : null,
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
  for (final width in <double>[320, 599, 600, 899, 900, 1280, 1920]) {
    testWidgets('ChromeBottomBar at ${width}px: no RenderFlex overflow', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      for (final quality in const [false, true]) {
        await tester.pumpWidget(_bar(width, quality: quality));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: 'quality: $quality');
      }
    });
  }

  for (final width in <double>[900, 1280, 1920]) {
    testWidgets('ChromeBottomBar at ${width}px with always-on-top: no '
        'overflow with all five buttons', (tester) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_bar(width, alwaysOnTop: true));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }
}
