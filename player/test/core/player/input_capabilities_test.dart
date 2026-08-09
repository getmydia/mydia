// Guards `InputCapabilities.touchPrimary`'s logic via its pure predicate.
// `kIsWeb` is compile-time false under `flutter test`, so the real getter can
// never be observed resolving the web branch on this host. Mirrors
// `platform_features_keyboard_test.dart`.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/core/player/platform_features.dart';

void main() {
  group('InputCapabilities.computeTouchPrimary', () {
    test('true on a native phone or tablet', () {
      expect(
        InputCapabilities.computeTouchPrimary(
          isNativeMobile: true,
          isWeb: false,
          coarsePointer: false,
        ),
        isTrue,
      );
    });

    test(
        'true on web with a coarse pointer — the actual defect this fixes: '
        'PlatformFeatures.isMobile returns false on web, so a phone browser '
        'was classified as neither mobile nor desktop and lost gestures', () {
      expect(
        InputCapabilities.computeTouchPrimary(
          isNativeMobile: false,
          isWeb: true,
          coarsePointer: true,
        ),
        isTrue,
      );
    });

    test('false on web with a fine pointer, so desktop browsers are unchanged',
        () {
      expect(
        InputCapabilities.computeTouchPrimary(
          isNativeMobile: false,
          isWeb: true,
          coarsePointer: false,
        ),
        isFalse,
      );
    });

    test('false on native desktop', () {
      expect(
        InputCapabilities.computeTouchPrimary(
          isNativeMobile: false,
          isWeb: false,
          coarsePointer: false,
        ),
        isFalse,
      );
    });

    test(
        'a coarse pointer off web is ignored, since native already answers '
        'through isNativeMobile and a touchscreen laptop keeps its desktop '
        'chrome', () {
      expect(
        InputCapabilities.computeTouchPrimary(
          isNativeMobile: false,
          isWeb: false,
          coarsePointer: true,
        ),
        isFalse,
      );
    });

    test('the real getter matches the pure predicate on this (non-web) host',
        () {
      expect(
        InputCapabilities.touchPrimary,
        InputCapabilities.computeTouchPrimary(
          isNativeMobile: PlatformFeatures.isMobile,
          isWeb: PlatformFeatures.isWeb,
          coarsePointer: false,
        ),
      );
    });

    test('supportsGestureControls tracks touchPrimary', () {
      expect(
        InputCapabilities.supportsGestureControls,
        InputCapabilities.touchPrimary,
      );
    });
  });
}
