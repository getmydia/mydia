// Pure predicate behind the television canvas scale. Tier-agnostic on purpose:
// `directionalPrimary` arrives as a parameter, so every branch is reachable
// from a plain `flutter test` run with no --dart-define.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/tv_canvas_scale.dart';

void main() {
  group('TvCanvasScale.computeScale', () {
    test('scales the reported Chromecast canvas 960x540 up to 1280x720', () {
      expect(
        TvCanvasScale.computeScale(
          logicalSize: const Size(960, 540),
          directionalPrimary: true,
        ),
        closeTo(0.75, 0.0001),
      );
    });

    test('leaves a canvas already at the target alone', () {
      expect(
        TvCanvasScale.computeScale(
          logicalSize: const Size(1280, 720),
          directionalPrimary: true,
        ),
        1.0,
      );
    });

    test('never scales a canvas larger than the target', () {
      expect(
        TvCanvasScale.computeScale(
          logicalSize: const Size(1920, 1080),
          directionalPrimary: true,
        ),
        1.0,
      );
    });

    test('is a no-op off the directional tier, whatever the size', () {
      for (final size in const [
        Size(960, 540),
        Size(1280, 720),
        Size(400, 800)
      ]) {
        expect(
          TvCanvasScale.computeScale(
              logicalSize: size, directionalPrimary: false),
          1.0,
          reason: 'phone and desktop behaviour must not change at $size',
        );
      }
    });

    test('takes the limiting axis, not the width alone', () {
      // Wider than 16:9: height is the binding constraint.
      expect(
        TvCanvasScale.computeScale(
          logicalSize: const Size(2560, 540),
          directionalPrimary: true,
        ),
        closeTo(0.75, 0.0001),
      );
    });
  });
}
