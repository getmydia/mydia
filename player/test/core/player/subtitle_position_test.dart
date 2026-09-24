import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/subtitle_position.dart';

void main() {
  const box = Size(1600, 900);

  group('subPosForLift', () {
    test('the rest lift leaves mpv at 100', () {
      expect(
        subPosForLift(
            lift: kSubtitleRestPadding,
            box: box,
            videoWidth: 1920,
            videoHeight: 1080),
        100,
      );
    });

    test('a picture filling the box shifts by the whole lift', () {
      // 16:9 into 16:9: displayed 900, no bar. 180 / 900 = 20%.
      expect(
        subPosForLift(lift: 180, box: box, videoWidth: 1920, videoHeight: 1080),
        closeTo(80, 0.001),
      );
    });

    test('a letterbox bar absorbs part of the lift', () {
      // 2.4:1 into 1600x900: displayed 666.67, bar 116.67 below it.
      // Shift 180 - 116.67 = 63.33, which is 9.5% of 666.67.
      expect(
        subPosForLift(lift: 180, box: box, videoWidth: 1920, videoHeight: 800),
        closeTo(90.5, 0.01),
      );
    });

    test('a bar taller than the lift needs no shift', () {
      expect(
        subPosForLift(lift: 100, box: box, videoWidth: 1920, videoHeight: 800),
        100,
      );
    });

    test('an unknown picture size falls back to the box height', () {
      expect(subPosForLift(lift: 180, box: box), closeTo(80, 0.001));
    });

    test('clamps at 0', () {
      expect(
        subPosForLift(
            lift: 2000, box: box, videoWidth: 1920, videoHeight: 1080),
        0,
      );
    });

    test('an empty box leaves mpv at 100', () {
      expect(subPosForLift(lift: 180, box: Size.zero), 100);
    });
  });
}
