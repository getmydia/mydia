import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/platform_updater.dart';

void main() {
  group('PlatformUpdater.supportedOnPlatform', () {
    test('web has no in-app updater', () {
      expect(
        PlatformUpdater.supportedOnPlatform(
          isWeb: true,
          isAndroid: false,
          isIOS: false,
        ),
        isFalse,
      );
    });

    test('iOS has no in-app updater', () {
      expect(
        PlatformUpdater.supportedOnPlatform(
          isWeb: false,
          isAndroid: false,
          isIOS: true,
        ),
        isFalse,
      );
    });

    test('Android has no in-app updater', () {
      expect(
        PlatformUpdater.supportedOnPlatform(
          isWeb: false,
          isAndroid: true,
          isIOS: false,
        ),
        isFalse,
      );
    });

    test('desktop ships an in-app updater', () {
      expect(
        PlatformUpdater.supportedOnPlatform(
          isWeb: false,
          isAndroid: false,
          isIOS: false,
        ),
        isTrue,
      );
    });
  });

  group('PlatformUpdater.supportedOnCurrentPlatform', () {
    // Guards against the two enumerations drifting apart: a platform that
    // reports support but has no concrete updater would surface a Settings
    // "Updates" section whose every action is a no-op. Only observable for
    // whichever platform the suite runs on, which is why the decision itself
    // is tested purely above.
    test('agrees with forCurrentPlatform on the platform under test', () {
      expect(
        PlatformUpdater.supportedOnCurrentPlatform,
        PlatformUpdater.forCurrentPlatform() != null,
      );
    });

    test('is true on the desktop platforms the suite runs on', () {
      // `flutter test` is always a non-web VM run, so this pins the desktop
      // answer against an accidental inversion of the predicate.
      expect(kIsWeb, isFalse);
      expect(PlatformUpdater.supportedOnCurrentPlatform, isTrue);
    });
  });
}
