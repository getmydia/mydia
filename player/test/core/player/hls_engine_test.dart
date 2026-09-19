import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/hls_engine.dart';

void main() {
  group('hidesNativeHls', () {
    test('hides every HLS content type a browser answers for', () {
      for (final type in kHlsContentTypes) {
        expect(
          hidesNativeHls(type, hlsJsUsable: true),
          isTrue,
          reason: 'media_kit asks about $type',
        );
      }
    });

    test('hides the type media_kit actually asks about', () {
      // Verbatim from media_kit's `_isHLS`. If this one stops matching, the
      // whole fix silently stops applying.
      expect(
        hidesNativeHls('application/vnd.apple.mpegurl', hlsJsUsable: true),
        isTrue,
      );
    });

    test('ignores parameters and case', () {
      expect(
        hidesNativeHls('APPLICATION/X-MPEGURL; codecs="avc1.4d401f"',
            hlsJsUsable: true),
        isTrue,
      );
    });

    test('leaves every other type to the browser', () {
      for (final type in [
        'video/mp4',
        'video/mp4; codecs="avc1.640028, mp4a.40.2"',
        'video/webm',
        'audio/mpeg',
        '',
      ]) {
        expect(hidesNativeHls(type, hlsJsUsable: true), isFalse,
            reason: 'should not touch $type');
      }
    });

    test('hides nothing when hls.js cannot run', () {
      // iOS Safari below 17.1: no MediaSource and no ManagedMediaSource, so
      // hls.js is not an option. Hiding the browser's own engine there would
      // leave no engine at all, which is worse than one that copes badly.
      for (final type in kHlsContentTypes) {
        expect(hidesNativeHls(type, hlsJsUsable: false), isFalse);
      }
    });
  });

  test('prepareHlsEngine is a no-op off the web', () async {
    // The VM run resolves the stub, so this only proves it stays awaitable
    // and silent. The browser behaviour is in hls_engine_web_test.dart.
    await expectLater(prepareHlsEngine(), completes);
  });
}
