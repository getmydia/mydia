// The VM half of the codec-support checks. `codec_support.dart` resolves to
// `codec_support_stub.dart` here, so this pins what native reports; the
// browser half lives in codec_support_web_test.dart and runs under
// `--platform chrome`.
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/codec_support.dart';

void main() {
  group('CodecSupport on native', () {
    test('never prefers a native HLS engine', () {
      // media_kit plays HLS through mpv/FFmpeg here, with no browser fork to
      // take. A true would block relayed playback on desktop and mobile, which
      // are not relayed at all.
      expect(CodecSupport.prefersNativeHls, isFalse);
    });

    test('has whatever hls.js needs, vacuously', () {
      // Same reason: there is no MSE dependency off the browser, so the
      // pre-flight check must never turn a native viewer away.
      expect(CodecSupport.hasHlsMediaSourceSupport, isTrue);
    });
  });
}
