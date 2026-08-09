// Guards `resolveWebMode`'s branch order directly. `kIsWeb` is a compile-time
// constant baked in per build target, so a `flutter test` run (always
// non-web) can never observe the real web backend resolve anything. Testing
// the extracted logic with explicit inputs is the only coverage available
// without a browser test target — the same reasoning as
// `platform_features_keyboard_test.dart` and `window_chrome_inset_test.dart`.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/fullscreen/fullscreen_mode.dart';

void main() {
  group('resolveWebMode', () {
    test('prefers the standard API, which keeps Mydia chrome', () {
      expect(
        resolveWebMode(
          documentFullscreenEnabled: true,
          videoElementFullscreenSupported: true,
        ),
        FullscreenMode.documentElement,
      );
    });

    test('standard API alone is enough', () {
      expect(
        resolveWebMode(
          documentFullscreenEnabled: true,
          videoElementFullscreenSupported: false,
        ),
        FullscreenMode.documentElement,
      );
    });

    test(
        'falls back to the video element when the document cannot go '
        'fullscreen — iPhone Safari below iOS 26, and any iframe without '
        'allow="fullscreen"', () {
      expect(
        resolveWebMode(
          documentFullscreenEnabled: false,
          videoElementFullscreenSupported: true,
        ),
        FullscreenMode.nativeVideoElement,
      );
    });

    test('unsupported when neither route exists, so the button is hidden', () {
      expect(
        resolveWebMode(
          documentFullscreenEnabled: false,
          videoElementFullscreenSupported: false,
        ),
        FullscreenMode.unsupported,
      );
    });
  });
}
