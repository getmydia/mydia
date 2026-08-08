// Runs only under `flutter test --platform chrome`: MediaSource and
// ManagedMediaSource are browser globals that dart:js_interop reads directly,
// and codec_support_web.dart is not reachable from a VM test run at all.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/codec_support_web.dart' as platform;

void main() {
  test('hasHlsMediaSourceSupport is true in a real browser', () {
    // Headless Chromium ships MediaSource, so this exercises the real @JS
    // lookup rather than merely compiling it. The unsupported branch (iOS
    // Safari below 17.1, lacking both MediaSource and ManagedMediaSource) is
    // not reproducible in CI Chrome and is left to manual verification.
    expect(platform.hasHlsMediaSourceSupport, isTrue);
  });

  test('prefersNativeHls is true in Chromium, which still plays', () {
    // Pins the measurement, because it is counter-intuitive and the reason
    // this getter must never be used to refuse playback. Chromium 149 answers
    // canPlayType('application/vnd.apple.mpegurl') with 'maybe', so media_kit
    // hands it `element.src` and never loads hls.js, on ordinary desktop
    // Chrome and not just on Safari. A `<video>` pointed at a Service
    // Worker-served manifest in this same browser was observed fetching the
    // manifest and its segment through the worker, so the native loader works
    // here. Anything that starts blocking viewers on this getter would block
    // desktop Chrome, and this test is what should make that obvious.
    expect(platform.prefersNativeHls, isTrue);
  });
}
