import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/traffic_lights_native.dart';

void main() {
  group('shouldControlTrafficLights', () {
    test('true hiding on windowed macOS', () {
      expect(
        shouldControlTrafficLights(
          platform: TargetPlatform.macOS,
          hidden: true,
          isFullscreen: false,
        ),
        isTrue,
      );
    });

    test('true restoring on windowed macOS', () {
      expect(
        shouldControlTrafficLights(
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
        shouldControlTrafficLights(
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
        shouldControlTrafficLights(
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
          shouldControlTrafficLights(
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
          shouldControlTrafficLights(
            platform: platform,
            hidden: false,
            isFullscreen: false,
          ),
          isFalse,
        );
      });
    }
  });
}
