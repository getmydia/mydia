// Panel goldens, narrow by design: the panel over a fixed synthetic backdrop
// at three widths, not full screenshots.
//
// DEVIATION FROM PLAN: the task brief called for `@TestOn('linux')`, generated
// inside `player/Dockerfile.test`. That was not possible in the environment
// these were produced in — no container runtime (docker/podman/colima/
// nerdctl/lima/finch) was available, and there is no viable fallback: CI
// (`.github/workflows/ci.yml`, `test-player` job) runs `flutter test` on
// `ubuntu-latest` *without* `--update-goldens`, and `matchesGoldenFile` fails
// on a missing reference image rather than creating one, so CI cannot
// bootstrap these on its own.
//
// Ruling: generate on macOS and pin `@TestOn('mac-os')` instead. Consequences:
//   - CI (ubuntu) will SKIP these tests rather than fail on platform-dependent
//     font rasterisation and blur rendering — it is not a green/red signal
//     for this file.
//   - They guard regressions only for local macOS runs, which is where this
//     project is developed day to day.
// To move this to Linux/CI later: regenerate the three PNGs inside a Linux
// environment with `flutter test --update-goldens`, re-pin the annotation
// below to `@TestOn('linux')`, and note that the existing macOS-generated
// images are NOT portable to Linux (or vice versa) — font hinting and the
// Gaussian blur backend both differ across platforms, so a straight copy
// would immediately mismatch pixel-for-pixel.
//
// LIMITATION: there is no `flutter_test_config.dart` in this project, so
// `MaterialIcons` never loads in the test binding and every glyph renders as
// its fallback "tofu" box rather than the real icon. These goldens freeze
// panel geometry and glass compositing (rim, fill gradient, saturation) —
// glyph *identity* is `icon_family_test.dart`'s job, not this file's.

@TestOn('mac-os')
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/platform_features.dart';
import 'package:player/presentation/widgets/video_controls/chrome_panel.dart';
import 'package:player/presentation/widgets/video_controls/panel_controls.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';
import 'package:player/presentation/widgets/video_controls/video_progress_bar.dart';

/// Wraps the synthetic backdrop *and* the panel in one [RepaintBoundary], so
/// they are captured as a single rasterized scene together — see
/// [_captureChromePanel] for why that matters.
const _sceneKey = Key('chrome-panel-golden-scene');

Widget _panel(double width) {
  final metrics = PanelMetrics.forWidth(width);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: RepaintBoundary(
        key: _sceneKey,
        child: Stack(
          children: [
            // Fixed synthetic backdrop: a gradient gives the glass something
            // with both bright and dark regions to refract.
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
            Center(
              child: ChromePanel(
                metrics: metrics,
                // Forced so images do not vary with the host platform.
                tier: PlayerGlassTier.full,
                // Episode nav wired unconditionally, matching real usage
                // whenever adjacent episodes exist (`PlaybackChrome` now
                // always passes both callbacks through — see its wiring
                // comment) — omitting them, as an earlier version of this
                // file did, understated real transport width by 104px and
                // hid how close the tablet/desktop tiers sit to their own
                // limits. `compact` (not the callbacks) is what actually
                // drops them below the mobile breakpoint: below that width
                // `PlaybackChrome` passes `compact: metrics.touchTargets`
                // to `TransportCluster`, and `TransportSurface.compact`
                // ignores every callback except play/pause regardless of
                // whether it was supplied — see that flag's own dartdoc for
                // the full layout reasoning. `chrome_panel_overflow_test
                // .dart` is the CI-visible guard for exactly which widths
                // this composition does and does not fit at.
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
                // `touchTarget` mirrors real wiring (see
                // `playback_chrome.dart`'s `_ScrubberRow`, which always
                // passes `metrics.touchTargets` through to
                // `VideoProgressBar`/`ProgressBarSurface`): the mobile tier
                // gets the larger 44px hit area, which also changes the
                // row's laid-out height. Hardcoding this to false, as the
                // brief's sample did, would make the mobile golden silently
                // diverge from what the app actually renders at that
                // breakpoint.
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

/// Rasterizes the [_sceneKey] boundary and crops the result down to just
/// [ChromePanel]'s own bounds.
///
/// This does **not** capture `find.byType(ChromePanel)` directly (the
/// brief's original approach) for two independent reasons, either of which
/// alone would make that approach wrong:
///
///  1. **Crop.** `matchesGoldenFile` on a `Finder` walks *upward* from the
///     found element's own render object to the nearest ancestor that
///     `isRepaintBoundary` (see `captureImage` in flutter_test's
///     `_matchers_io.dart`), then rasterizes *that* ancestor's full
///     `paintBounds`. `ChromePanel`'s own outermost render object (a
///     `ConstrainedBox`) is not itself a repaint boundary — the one inside
///     `GlassSurface.playerChrome` sits *below* it in the tree, so the
///     upward walk never reaches it and instead resolves to whatever much
///     larger ancestor boundary happens to exist above the panel (in
///     practice, something close to the full test viewport). Naively
///     wrapping just `ChromePanel` in its own `RepaintBoundary` fixes the
///     crop, but creates problem 2:
///
///  2. **Backdrop.** `BackdropFilter` blurs "the existing painted content of
///     the scene" (its own dartdoc) — i.e. whatever was already rasterized
///     into the *same* layer-tree walk before it. A `RepaintBoundary` placed
///     directly around `ChromePanel` isolates it into its own standalone
///     scene for `toImage()`, with nothing painted before the
///     `BackdropFilter` inside `GlassSurface` — so it blurs a blank/
///     transparent canvas instead of the synthetic backdrop. The resulting
///     image is the fill color alone, at the documented top/bottom alphas,
///     over full transparency: confirmed by sampling the very first
///     `--update-goldens` attempt with `magick`, which showed the tint's raw
///     RGB (`(11,14,20)`, `DepthTokens.playerChromeTint`) at exactly
///     alpha 142/255 (≈0.56) fading to 98/255 (≈0.38) top-to-bottom, with
///     *zero* trace of the tan/navy backdrop underneath it — no live blur,
///     no saturation boost visible, because there was nothing behind the
///     filter to blur or saturate.
///
/// Putting the `RepaintBoundary` around the backdrop *and* the panel
/// together (so `BackdropFilter` has real content behind it when the scene
/// rasterizes) and cropping the resulting image to `ChromePanel`'s bounds
/// afterward gets both properties at once.
Future<ui.Image> _captureChromePanel(WidgetTester tester) async {
  final panelRect = tester.getRect(find.byType(ChromePanel));
  final pixelRatio = tester.view.devicePixelRatio;

  final cropped = await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_sceneKey),
    );
    final scene = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      return await _crop(scene, panelRect, pixelRatio);
    } finally {
      scene.dispose();
    }
  });

  return cropped ??
      (throw StateError(
        'tester.runAsync returned null while capturing the chrome panel '
        'golden scene',
      ));
}

/// Crops [scene] to the physical-pixel rectangle corresponding to
/// [logicalRect] (scaled by [pixelRatio]), returning a new, smaller image.
///
/// Asserts [srcRect] is integral (each edge a whole pixel) and paints with
/// `FilterQuality.none`: with a fractional `srcRect`, the default
/// `FilterQuality.low` would resample the source image (bilinear
/// interpolation across a partial pixel), making the golden's exact bytes
/// depend on the interpolation backend rather than purely on rendering
/// output — a second, avoidable source of cross-platform drift on top of the
/// documented font/blur one. All three cases here happen to be integral
/// today (whole-pixel `physicalSize`s and `devicePixelRatio: 1.0`), but nothing
/// upstream guarantees that stays true, so this is asserted rather than
/// assumed.
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
  for (final (name, width) in <(String, double)>[
    ('desktop', 1600),
    ('tablet', 800),
    ('mobile', 400),
  ]) {
    testWidgets('chrome panel golden — $name', (tester) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_panel(width));
      await tester.pumpAndSettle();

      final image = await _captureChromePanel(tester);
      await expectLater(
        image,
        matchesGoldenFile('goldens/chrome_panel_$name.png'),
      );
    });
  }
}
