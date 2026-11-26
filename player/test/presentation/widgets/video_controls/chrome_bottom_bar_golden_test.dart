// Bottom bar goldens, narrow by design: the bar over its scrim and a fixed
// synthetic backdrop at two widths, not full screenshots.
//
// Generated on macOS and pinned `@TestOn('mac-os')`: font rasterisation
// differs across platforms, so these images are not portable to Linux and
// CI (ubuntu) skips this file. Regenerate with
// `flutter test --update-goldens <this file>` on a Mac.
//
// LIMITATION: there is no `flutter_test_config.dart` in this project, so
// `MaterialIcons` never loads in the test binding and every glyph renders as
// its fallback "tofu" box. These goldens freeze bar geometry, the pill
// material and the scrim; glyph identity is `icon_family_test.dart`'s job.

@TestOn('mac-os')
// Out of very_good's bundle, where @TestOn no longer applies and these
// macOS-generated goldens would run (and fail) on Linux.
@Tags(['skip_very_good_optimization'])
library;

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/widgets/video_controls/chrome_bottom_bar.dart';
import 'package:player/presentation/widgets/video_controls/chrome_scrim.dart';
import 'package:player/presentation/widgets/video_controls/panel_controls.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';
import 'package:player/presentation/widgets/video_controls/video_progress_bar.dart';

/// Wraps the synthetic backdrop, the scrim *and* the bar in one
/// [RepaintBoundary], so they rasterize as a single scene. Capturing the bar
/// through its own boundary would drop everything painted behind it.
const _sceneKey = Key('chrome-bottom-bar-golden-scene');

Widget _bar(double width) {
  final metrics = ChromeMetrics.forWidth(width);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    // TransportSurface and SecondaryCluster read context.l10n.
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: RepaintBoundary(
        key: _sceneKey,
        child: Stack(
          children: [
            // Fixed synthetic backdrop: bright and dark regions for the
            // scrim and the pill fill to read against.
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFE8C39E), Color(0xFF1B3A5C)],
                  ),
                ),
              ),
            ),
            ChromeScrim(bottomHeight: metrics.barHeight),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              // Mirrors `PlaybackChrome`'s pointer-tier wiring: episode nav
              // passed unconditionally (`compact` drops it below the mobile
              // breakpoint), volume always supplied (the bar hides it by
              // tier), the quality button and per-tier gap as production
              // passes them, and the scrubber at `metrics.touchTargets`.
              child: ChromeBottomBar(
                metrics: metrics,
                elapsed: const Text(
                  '12:34',
                  style: TextStyle(color: Colors.white),
                ),
                remaining: const Text(
                  '-31:26',
                  style: TextStyle(color: Colors.white),
                ),
                transport: TransportSurface(
                  isPlaying: true,
                  onPreviousEpisode: () {},
                  onNextEpisode: () {},
                  compact: metrics.compactTransport,
                ),
                volume: VolumeSurface(
                  volume: 70,
                  onVolumeChanged: (_) {},
                  onToggleMute: () {},
                ),
                secondary: SecondaryCluster(
                  audioTrackCount: 2,
                  onSubtitleTap: () {},
                  gap: metrics.secondaryGap,
                  onQualityTap: () {},
                  onFullscreenTap: () {},
                ),
                scrubber: ProgressBarSurface(
                  progress: 0.35,
                  buffered: 0.55,
                  touchTarget: metrics.touchTargets,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Rasterizes the [_sceneKey] boundary and crops it to [ChromeBottomBar]'s
/// own bounds.
Future<ui.Image> _captureBar(WidgetTester tester) async {
  final barRect = tester.getRect(find.byType(ChromeBottomBar));
  final pixelRatio = tester.view.devicePixelRatio;

  final cropped = await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_sceneKey),
    );
    final scene = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      return await _crop(scene, barRect, pixelRatio);
    } finally {
      scene.dispose();
    }
  });

  return cropped ??
      (throw StateError(
        'tester.runAsync returned null while capturing the bottom bar '
        'golden scene',
      ));
}

/// Crops [scene] to [logicalRect] scaled by [pixelRatio]. The source rect
/// must be integral and is painted with `FilterQuality.none`, so cropping
/// never resamples and the bytes depend only on rendering.
Future<ui.Image> _crop(
  ui.Image scene,
  Rect logicalRect,
  double pixelRatio,
) async {
  final srcRect = Rect.fromLTWH(
    logicalRect.left * pixelRatio,
    logicalRect.top * pixelRatio,
    logicalRect.width * pixelRatio,
    logicalRect.height * pixelRatio,
  );
  assert(
    srcRect.left == srcRect.left.roundToDouble() &&
        srcRect.top == srcRect.top.roundToDouble() &&
        srcRect.width == srcRect.width.roundToDouble() &&
        srcRect.height == srcRect.height.roundToDouble(),
    'srcRect must be integral so cropping never resamples: $srcRect',
  );
  final width = srcRect.width.round();
  final height = srcRect.height.round();

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImageRect(
    scene,
    srcRect,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..filterQuality = FilterQuality.none,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

void main() {
  for (final width in <double>[1280, 390]) {
    testWidgets('chrome bottom bar golden at ${width.toInt()}px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_bar(width));
      await tester.pumpAndSettle();

      final image = await _captureBar(tester);
      await expectLater(
        image,
        matchesGoldenFile('goldens/chrome_bottom_bar_${width.toInt()}.png'),
      );
    });
  }
}
