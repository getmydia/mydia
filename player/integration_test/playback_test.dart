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

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:player/core/playback/frame_stats_sampler_native.dart'
    show renderPathProperty;

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

  setUpAll(ensureTestBootstrap);

  testWidgets('a local clip decodes and advances', (tester) async {
    final rig = await pumpPlayerScreen(tester, sdrClip);
    await waitFor(
      tester,
      'time-pos past 2 s',
      () async => (double.tryParse(await rig.prop('time-pos')) ?? 0) > 2.0,
    );
    expect(double.parse(await rig.prop('estimated-vf-fps')), greaterThan(0));
    await rig.close(tester);
  });

  // Flutter 3.50 left no EGL context current on the GTK thread, so upstream
  // media_kit_video found no display and fell back to software rendering
  // without a word to the app: playback still advances. The vendored patch
  // resolves the platform display instead (MYDIA_PATCHES.md).
  //
  // This VM cannot assert `hw` itself. Its Mesa is llvmpipe under Xvfb, and
  // there the patched output gets past the display check and then fails
  // `eglMakeCurrent` on its surfaceless context (EGL_BAD_ACCESS, 0x3002),
  // so it publishes `sw` either way. What does tell the two apart is the
  // reason on stderr: only the unpatched lookup reports `EGL display or
  // context is invalid`.
  testWidgets(
    'Linux video renders on the hardware path',
    (tester) async {
      final rig = await pumpPlayerScreen(tester, sdrClip);
      // Set at the end of the output's setup, after every line it prints.
      await waitFor(
        tester,
        'render path published',
        () async => (await rig.prop(renderPathProperty)).isNotEmpty,
      );
      debugPrint(
        '[playback_test] $renderPathProperty='
        '${await rig.prop(renderPathProperty)}',
      );
      final stderr = rig.nativeStderr;
      expect(
        stderr,
        contains('media_kit: VideoOutput:'),
        reason:
            'the video output reported nothing, so the check below '
            'would pass on an empty capture',
      );
      expect(stderr, isNot(contains('EGL display or context is invalid')));
      await rig.close(tester);
    },
    // `testWidgets` takes no reason: the render path is published on Linux
    // only.
    skip: !Platform.isLinux,
  );
}
