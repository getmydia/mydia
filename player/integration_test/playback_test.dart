// Real playback in the player E2E: the real `PlayerScreen` and a real
// media_kit `Player` play local clips through the app's libmpv, on the
// texture path media_kit_video drives on Linux.
//
// CI runs it from `all_tests.dart` in the player-e2e VM, where
// `scripts/e2e/run-tests.sh` writes the clips with ffmpeg and passes their
// directory as `--dart-define=MYDIA_E2E_CLIPS`. Without that define the
// file registers one skipped test; with it and a clip missing, it fails
// naming the path, so a wrong path never passes as a skip.

import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' show SubtitleTrack;
import 'package:media_kit_video/media_kit_video.dart'
    show defaultExitNativeFullscreen;
import 'package:player/core/playback/frame_stats_sampler_native.dart'
    show renderPathProperty, samplerFor;
import 'package:player/core/theme/app_theme.dart' show kAppFontFamily;
import 'package:player/core/window/native_window_host.dart';
import 'package:player/core/window/window_controller_native.dart';
import 'package:player/core/window/window_fullscreen.dart';
import 'package:player/core/window/window_fullscreen_controller.dart';
import 'package:player/presentation/widgets/video_controls/panel_controls.dart'
    show SecondaryCluster;

import 'helpers/playback_rig.dart';
import 'helpers/test_bootstrap.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (e2eClipsDir.isEmpty) {
    test('playback', () {}, skip: 'MYDIA_E2E_CLIPS is not set');
    return;
  }
  final missing = [
    for (final name in [sdrClip, subsClip])
      if (!File(clipPath(name)).existsSync()) clipPath(name),
  ];
  if (missing.isNotEmpty) {
    test('playback clips', () {
      fail(
        'MYDIA_E2E_CLIPS is set but these are missing: ${missing.join(', ')}',
      );
    });
    return;
  }

  // As `desktop_window_native.dart` does in the app: the player's
  // fullscreen state follows `windowFullscreenSignal`, which only this
  // listener updates. Without it the screen never learns the window went
  // fullscreen and its button keeps asking to enter.
  WindowFullscreenController? fullscreen;
  setUpAll(() async {
    await ensureTestBootstrap();
    if (!Platform.isLinux) return;
    final controller = WindowFullscreenController(
      window: nativeWindowController(),
    );
    await controller.seed();
    NativeWindowHost.instance.addListener(controller);
    fullscreen = controller;
  });
  tearDownAll(() {
    final controller = fullscreen;
    if (controller != null) {
      NativeWindowHost.instance.removeListener(controller);
    }
  });

  testWidgets('a local clip decodes and advances', (tester) async {
    final rig = await pumpPlayerScreen(tester, sdrClip);
    await waitFor(
      tester,
      'time-pos past 2 s',
      () async => (double.tryParse(await rig.prop('time-pos')) ?? 0) > 2.0,
    );
    expect(
      double.tryParse(await rig.prop('estimated-vf-fps')) ?? 0,
      greaterThan(0),
      reason: 'mpv estimated no output frame rate',
    );
    await rig.close(tester);
  });

  // Flutter 3.50 left no EGL context current on the GTK thread, so upstream
  // media_kit_video found no display and fell back to software rendering
  // without a word to the app: playback still advances. The vendored patch
  // resolves the platform display instead (MYDIA_PATCHES.md).
  //
  // A published `hw` passes outright: only the patched lookup gets there.
  // Today this VM does not. Its Mesa is llvmpipe under Xvfb, and there the
  // patched output gets past the display check and then fails
  // `eglMakeCurrent` on its surfaceless context (EGL_BAD_ACCESS, 0x3002),
  // so it publishes `sw` whichever lookup ran. What tells the two apart
  // then is the reason on stderr: only the unpatched lookup reports `EGL
  // display or context is invalid`. Success lines go to stdout (`g_print`),
  // so stderr holds a `media_kit:` line only on the software path.
  testWidgets(
    'Linux video output does not hit the EGL display failure',
    (tester) async {
      final rig = await pumpPlayerScreen(tester, sdrClip);
      // Set at the end of the output's setup, after every line it prints.
      await waitFor(
        tester,
        'render path published',
        () async => (await rig.prop(renderPathProperty)).isNotEmpty,
      );
      final renderPath = await rig.prop(renderPathProperty);
      debugPrint('[playback_test] $renderPathProperty=$renderPath');
      // libmpv returns it JSON-quoted (`"hw"`); the sampler matches both.
      final hardware = renderPath == 'hw' || renderPath == '"hw"';
      final stderr = rig.nativeStderr;
      if (!hardware) {
        expect(
          stderr,
          contains('media_kit: VideoOutput:'),
          reason:
              'the video output reported nothing, so the check below '
              'would pass on an empty capture',
        );
      }
      expect(stderr, isNot(contains('EGL display or context is invalid')));
      await rig.close(tester);
    },
    // `testWidgets` takes no reason: the render path is published on Linux
    // only.
    skip: !Platform.isLinux,
  );

  // The material_ui migration left subtitles in Roboto: media_kit wraps the
  // cue in flutter/material's `Material`, whose theme is not the app's, so
  // the family has to be named in `subtitle_size.dart`.
  testWidgets('a text subtitle draws in the app font', (tester) async {
    final rig = await pumpPlayerScreen(tester, subsClip);
    final player = rig.player;
    bool english(SubtitleTrack t) => t.language == 'eng';
    await waitFor(
      tester,
      'the English subtitle track',
      () => player.state.tracks.subtitle.any(english),
    );
    final eng = player.state.tracks.subtitle.firstWhere(english);
    if (player.state.track.subtitle.id != eng.id) {
      debugPrint(
        '[playback_test] subtitle track at load: '
        '${player.state.track.subtitle.id}; selecting ${eng.id}',
      );
      await player.setSubtitleTrack(eng);
    }
    final cue = find.byWidgetPredicate(
      (w) => w is Text && (w.data?.contains(subtitleText) ?? false),
    );
    await waitFor(
      tester,
      'the subtitle cue on screen',
      () => cue.evaluate().isNotEmpty,
    );
    final element = cue.evaluate().first;
    final text = element.widget as Text;
    final style = DefaultTextStyle.of(element).style.merge(text.style);
    expect(style.fontFamily, kAppFontFamily);
    await rig.close(tester);
  });

  // The button once entered fullscreen and then had no way back out.
  testWidgets(
    'the fullscreen button enters and leaves fullscreen',
    (tester) async {
      final window = nativeWindowController();
      expect(
        await window.isFullScreen(),
        isFalse,
        reason: 'the window has to start windowed',
      );
      // A failure while fullscreen must not leave the window that way.
      addTearDown(() async {
        if (await window.isFullScreen()) await defaultExitNativeFullscreen();
      });
      final rig = await pumpPlayerScreen(tester, sdrClip);
      await waitFor(
        tester,
        'time-pos past 0.5 s',
        () async => (double.tryParse(await rig.prop('time-pos')) ?? 0) > 0.5,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);

      await _clickFullscreen(tester, mouse);
      await waitFor(
        tester,
        'the window to report fullscreen',
        () async => await window.isFullScreen() && windowFullscreen.value,
      );

      await _clickFullscreen(tester, mouse);
      await waitFor(
        tester,
        'the window to report windowed',
        () async => !await window.isFullScreen() && !windowFullscreen.value,
      );
      await rig.close(tester);
    },
    // `testWidgets` takes no reason: the listener above is wired on Linux
    // only.
    skip: !Platform.isLinux,
  );

  // Quitting mid-playback used to crash the app.
  testWidgets('closing mid-playback disposes the player', (tester) async {
    final rig = await pumpPlayerScreen(tester, sdrClip);
    await waitFor(
      tester,
      'time-pos past 1 s',
      () async => (double.tryParse(await rig.prop('time-pos')) ?? 0) > 1.0,
    );
    await rig.close(tester);
    await pumpBounded(
      tester,
      'a frame after closing',
      () => tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('after close'),
        ),
      ),
    );
    expect(find.text('after close'), findsOneWidget);
  });

  // The software video output queued its redraws with a bare pointer, so a
  // redraw still queued when the screen closed ran on the freed output and
  // could lock a freed mutex, freezing the GTK thread (and with it every
  // Dart timer) for good. Closing just as the output starts delivering
  // frames is the window; a few rounds make hitting it likely. A freeze
  // here cannot fail from inside the test: run-tests.sh's watchdog ends
  // the run and prints the app's native stacks.
  testWidgets(
    'closing right after opening leaves the app responsive',
    (tester) async {
      for (var round = 1; round <= 5; round++) {
        final rig = await pumpPlayerScreen(tester, sdrClip);
        await waitFor(
          tester,
          'render path published (round $round)',
          () async => (await rig.prop(renderPathProperty)).isNotEmpty,
        );
        await rig.close(tester);
      }
      await pumpBounded(
        tester,
        'a frame after the early closes',
        () => tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Text('after early closes'),
          ),
        ),
      );
      expect(find.text('after early closes'), findsOneWidget);
    },
    // `testWidgets` takes no reason: the render path is published on Linux
    // only.
    skip: !Platform.isLinux,
  );

  // libmpv returns the render path JSON-quoted (`"sw"`), and the sampler
  // once matched only the bare word, so the stats panel never reported
  // software rendering.
  testWidgets(
    'the stats sampler reports the Linux render path',
    (tester) async {
      final rig = await pumpPlayerScreen(tester, sdrClip);
      // The render path is published while the output is set up, before
      // mpv has the frame counters a reading needs.
      await waitFor(
        tester,
        'time-pos past 1 s',
        () async => (double.tryParse(await rig.prop('time-pos')) ?? 0) > 1.0,
      );
      await waitFor(
        tester,
        'render path published',
        () async => (await rig.prop(renderPathProperty)).isNotEmpty,
      );
      final stats = await samplerFor(rig.player, panel: true).sample();
      expect(stats, isNotNull, reason: 'mpv counters did not parse');
      expect(
        stats?.softwareRendering,
        isNotNull,
        reason:
            '$renderPathProperty is '
            '${await rig.prop(renderPathProperty)}, and the sampler did not '
            'recognise it',
      );
      await rig.close(tester);
    },
    // `testWidgets` takes no reason: the render path is published on Linux
    // only.
    skip: !Platform.isLinux,
  );
}

/// Hovers the fullscreen button with [mouse], which reveals the chrome if it
/// has auto-hidden and holds it open, then clicks it.
Future<void> _clickFullscreen(WidgetTester tester, TestGesture mouse) async {
  final button = find.byKey(SecondaryCluster.fullscreenKey);
  await waitFor(
    tester,
    'the fullscreen button',
    () => button.evaluate().isNotEmpty,
  );
  final center = tester.getCenter(button);
  await mouse.moveTo(center);
  await waitFor(
    tester,
    'the chrome to show the fullscreen button',
    () => button.hitTestable().evaluate().isNotEmpty,
  );
  await mouse.down(center);
  await mouse.up();
  await pumpBounded(tester, 'a frame after the click', tester.pump);
}
