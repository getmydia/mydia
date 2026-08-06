import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/traffic_lights_native.dart';

void main() {
  group('shouldControlTrafficLights', () {
    test('true on windowed macOS', () {
      expect(
        shouldControlTrafficLights(
          platform: TargetPlatform.macOS,
          isFullscreen: false,
        ),
        isTrue,
      );
    });

    test('false on fullscreen macOS — the OS already hides them there', () {
      expect(
        shouldControlTrafficLights(
          platform: TargetPlatform.macOS,
          isFullscreen: true,
        ),
        isFalse,
      );
    });

    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      test('false on ${platform.name} — no traffic lights there', () {
        expect(
          shouldControlTrafficLights(
            platform: platform,
            isFullscreen: false,
          ),
          isFalse,
        );
      });
    }
  });
}
