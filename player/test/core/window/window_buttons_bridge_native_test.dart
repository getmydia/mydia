import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/window_buttons_bridge_native.dart';

void main() {
  group('shouldCallNativeButtonBridge', () {
    test('true hiding on windowed macOS', () {
      expect(
        shouldCallNativeButtonBridge(
          platform: TargetPlatform.macOS,
          hidden: true,
          isFullscreen: false,
        ),
        isTrue,
      );
    });

    test('true restoring on windowed macOS', () {
      expect(
        shouldCallNativeButtonBridge(
          platform: TargetPlatform.macOS,
          hidden: false,
          isFullscreen: false,
        ),
        isTrue,
      );
    });

    test(
        'false hiding on fullscreen macOS — the OS already hides them '
        'there', () {
      expect(
        shouldCallNativeButtonBridge(
          platform: TargetPlatform.macOS,
          hidden: true,
          isFullscreen: true,
        ),
        isFalse,
      );
    });

    test(
        'true restoring on fullscreen macOS — a restore is always safe to '
        'pass through, so the dispose() safety net still reaches native '
        'code even when the player is torn down while still fullscreen', () {
      expect(
        shouldCallNativeButtonBridge(
          platform: TargetPlatform.macOS,
          hidden: false,
          isFullscreen: true,
        ),
        isTrue,
      );
    });

    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      test('false hiding on ${platform.name} — no traffic lights there', () {
        expect(
          shouldCallNativeButtonBridge(
            platform: platform,
            hidden: true,
            isFullscreen: false,
          ),
          isFalse,
        );
      });

      test(
          'false restoring on ${platform.name} — no traffic lights there '
          'either', () {
        expect(
          shouldCallNativeButtonBridge(
            platform: platform,
            hidden: false,
            isFullscreen: false,
          ),
          isFalse,
        );
      });
    }

    test(
        'false on Linux, where the buttons are Flutter-drawn and the native '
        'bridge has nothing to hide', () {
      expect(
        shouldCallNativeButtonBridge(
          platform: TargetPlatform.linux,
          hidden: true,
          isFullscreen: false,
        ),
        isFalse,
      );
    });
  });
}
