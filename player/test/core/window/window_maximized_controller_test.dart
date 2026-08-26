import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/window_maximized_controller.dart';

import 'fake_window_controller.dart';

void main() {
  group('WindowMaximizedController', () {
    test('seed reads the window once, for a launch into a maximized window',
        () async {
      final window = FakeWindowController(maximized: true);
      final signal = ValueNotifier(false);
      final controller =
          WindowMaximizedController(window: window, signal: signal);

      await controller.seed();

      expect(signal.value, isTrue);
    });

    test('seed leaves the signal alone when the read throws', () async {
      final window = _ThrowingWindowController();
      final signal = ValueNotifier(false);
      final controller =
          WindowMaximizedController(window: window, signal: signal);

      await controller.seed();

      expect(signal.value, isFalse);
    });

    test('tracks the window maximize and unmaximize events', () {
      final signal = ValueNotifier(false);
      final controller = WindowMaximizedController(
        window: FakeWindowController(),
        signal: signal,
      );

      controller.onWindowMaximize();
      expect(signal.value, isTrue);

      controller.onWindowUnmaximize();
      expect(signal.value, isFalse);
    });
  });
}

/// Fails every read, to drive the branch where startup must not fail over
/// window chrome.
class _ThrowingWindowController extends FakeWindowController {
  @override
  Future<bool> isMaximized() async => throw StateError('no window');
}
