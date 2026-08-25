// Guards `InputCapabilities.touchPrimary` and `.directionalPrimary` through
// their pure predicates. `kIsWeb` is compile-time false under `flutter test`,
// so the real getters can never be observed resolving the web branch on this
// host. Mirrors `platform_features_keyboard_test.dart`.

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
          directionalPrimary: false,
        ),
        isTrue,
      );
    });

    test(
        'true on web with a coarse pointer, the actual defect this fixes: '
        'PlatformFeatures.isMobile returns false on web, so a phone browser '
        'was classified as neither mobile nor desktop and lost gestures', () {
      expect(
        InputCapabilities.computeTouchPrimary(
          isNativeMobile: false,
          isWeb: true,
          coarsePointer: true,
          directionalPrimary: false,
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
          directionalPrimary: false,
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
          directionalPrimary: false,
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
          directionalPrimary: false,
        ),
        isFalse,
      );
    });

    test(
        'false on Android TV, which reports isNativeMobile true and would '
        'otherwise wire up tap and double-tap gestures for a remote', () {
      expect(
        InputCapabilities.computeTouchPrimary(
          isNativeMobile: true,
          isWeb: false,
          coarsePointer: false,
          directionalPrimary: true,
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
          directionalPrimary: InputCapabilities.directionalPrimary,
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

  group('InputCapabilities.computeDirectionalPrimary', () {
    test('true on Android reporting the leanback system feature', () {
      expect(
        InputCapabilities.computeDirectionalPrimary(
          isNativeAndroid: true,
          hasLeanback: true,
          forcedTv: false,
        ),
        isTrue,
      );
    });

    test('false on an Android phone, which has no leanback feature', () {
      expect(
        InputCapabilities.computeDirectionalPrimary(
          isNativeAndroid: true,
          hasLeanback: false,
          forcedTv: false,
        ),
        isFalse,
      );
    });

    test('false off Android even if a stale probe result says leanback', () {
      expect(
        InputCapabilities.computeDirectionalPrimary(
          isNativeAndroid: false,
          hasLeanback: true,
          forcedTv: false,
        ),
        isFalse,
      );
    });

    test(
        'the developer override forces the mode on without Android, so the '
        'TV path can be exercised on a desktop host or an emulator', () {
      expect(
        InputCapabilities.computeDirectionalPrimary(
          isNativeAndroid: false,
          hasLeanback: false,
          forcedTv: true,
        ),
        isTrue,
      );
    });

    test('directionalPrimary is false before initialize() has run', () {
      // Skipped under the developer override, which exists precisely so the
      // whole suite can be run in television mode. `forcedTv` short-circuits
      // `directionalPrimary` to true ahead of the probe, so asserting false
      // here would fail that run for the one reason it is not about.
      if (InputCapabilities.forcedTv) return;
      expect(InputCapabilities.directionalPrimary, isFalse);
    });
  });
}
