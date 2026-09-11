import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/video_output_config.dart';

void main() {
  group('videoControllerConfigurationFor', () {
    test('Android asks for the zero-copy hardware decoder', () {
      final config = videoControllerConfigurationFor(
        TargetPlatform.android,
        isWeb: false,
      );

      // `mediacodec-copy` reads every frame back into CPU memory, which
      // saturates one core on low-power Android TV hardware and caps playback
      // below realtime. See the module doc for the measurements.
      expect(config.hwdec, androidZeroCopyHwdec);
      expect(config.hwdec, isNot(contains('copy')));
    });

    test('Android keeps media_kit rendering the video, not a SurfaceView', () {
      final config = videoControllerConfigurationFor(
        TargetPlatform.android,
        isWeb: false,
      );

      // `vo=mediacodec_embed` would be faster still, but mpv then stops
      // compositing and subtitles and the OSD disappear. Leaving `vo` unset
      // keeps media_kit's `gpu`, which is what makes the zero-copy decoder
      // safe to use here.
      expect(config.vo, isNull);
    });

    test('web keeps the media_kit default even though it reports Android', () {
      // A mobile browser reports TargetPlatform.android, but there is no
      // libmpv there to hand an hwdec name to.
      final config = videoControllerConfigurationFor(
        TargetPlatform.android,
        isWeb: true,
      );

      expect(config.hwdec, isNull);
    });

    for (final platform in const [
      TargetPlatform.iOS,
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.fuchsia,
    ]) {
      test('$platform keeps the media_kit default', () {
        // `mediacodec` is an Android-only decoder name.
        final config = videoControllerConfigurationFor(
          platform,
          isWeb: false,
        );

        expect(config.hwdec, isNull);
      });
    }
  });
}
