import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/window_fullscreen_controller.dart';

import 'fake_window_controller.dart';

void main() {
  group('WindowFullscreenController', () {
    test(
        'seeds from the window, so a window already fullscreen at startup '
        'does not report windowed until the first event', () async {
      final signal = ValueNotifier(false);
      final controller = WindowFullscreenController(
        window: FakeWindowController(fullScreen: true),
        signal: signal,
      );

      await controller.seed();

      expect(signal.value, isTrue);
    });

    test('seeding a windowed window leaves the signal false', () async {
      final signal = ValueNotifier(false);
      final controller = WindowFullscreenController(
        window: FakeWindowController(fullScreen: false),
        signal: signal,
      );

      await controller.seed();

      expect(signal.value, isFalse);
    });

    test('enter and leave events drive the signal', () {
      final signal = ValueNotifier(false);
      final controller = WindowFullscreenController(
        window: FakeWindowController(),
        signal: signal,
      );

      controller.onWindowEnterFullScreen();
      expect(signal.value, isTrue);

      controller.onWindowLeaveFullScreen();
      expect(signal.value, isFalse);
    });

    test('notifies once per transition, not once per event', () {
      final signal = ValueNotifier(false);
      final controller = WindowFullscreenController(
        window: FakeWindowController(),
        signal: signal,
      );
      var notifications = 0;
      signal.addListener(() => notifications++);

      controller.onWindowEnterFullScreen();
      controller.onWindowEnterFullScreen();
      controller.onWindowEnterFullScreen();

      expect(notifications, 1);
    });

    test(
        'a seed that throws leaves the signal at its default rather than '
        'propagating, since startup must not fail over window chrome',
        () async {
      final signal = ValueNotifier(false);
      final controller = WindowFullscreenController(
        window: _ThrowingFullScreenController(),
        signal: signal,
      );

      await expectLater(controller.seed(), completes);
      expect(signal.value, isFalse);
    });
  });
}

class _ThrowingFullScreenController extends FakeWindowController {
  @override
  Future<bool> isFullScreen() async => throw StateError('no window');
}
