import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/window_frame_state.dart';

void main() {
  group('WindowFrameState.fromChannel', () {
    test('reads all three flags', () {
      expect(
        WindowFrameState.fromChannel(
          const {'maximized': true, 'tiled': false, 'fullscreen': true},
        ),
        const WindowFrameState(maximized: true, fullscreen: true),
      );
    });

    test('a missing or non-bool flag reads as false', () {
      expect(
        WindowFrameState.fromChannel(const {'tiled': 'yes'}),
        WindowFrameState.floating,
      );
    });

    test('anything that is not a map is the floating state', () {
      expect(WindowFrameState.fromChannel(null), WindowFrameState.floating);
      expect(
          WindowFrameState.fromChannel('maximized'), WindowFrameState.floating);
    });
  });

  group('isFloating', () {
    test('true only with every flag clear', () {
      expect(WindowFrameState.floating.isFloating, isTrue);
      expect(const WindowFrameState(maximized: true).isFloating, isFalse);
      expect(const WindowFrameState(tiled: true).isFloating, isFalse);
      expect(const WindowFrameState(fullscreen: true).isFloating, isFalse);
    });
  });
}
