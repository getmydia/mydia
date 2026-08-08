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
}
