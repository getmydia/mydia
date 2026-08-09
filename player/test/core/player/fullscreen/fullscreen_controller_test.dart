// The controller's whole job is that its notifier reports observed state
// rather than requested state. Every test here is written against that: a
// backend that accepts a request but never reports must leave the notifier
// false, because that is precisely the bug this replaces — `PlayerScreen`
// used to flip `_isFullscreen` inside `setState` before asking the platform,
// so on iPhone Safari the icon said "exit fullscreen" over an inline video.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/player/fullscreen/fullscreen_backend.dart';
import 'package:player/core/player/fullscreen/fullscreen_controller.dart';
import 'package:player/core/player/fullscreen/fullscreen_mode.dart';

void main() {
  group('FullscreenController', () {
    test('starts windowed', () {
      final controller = FullscreenController(
        backendFactory: (onChange) => _FakeBackend(onChange),
      );
      addTearDown(controller.dispose);

      expect(controller.isFullscreen.value, isFalse);
    });

    test('enter forwards to the backend', () {
      late _FakeBackend backend;
      final controller = FullscreenController(
        backendFactory: (onChange) => backend = _FakeBackend(onChange),
      );
      addTearDown(controller.dispose);

      controller.enter();

      expect(backend.enterCalls, 1);
    });

    test(
        'a backend that accepts the request but never reports leaves the '
        'notifier false — the iPhone Safari case', () {
      final controller = FullscreenController(
        backendFactory: (onChange) => _SilentBackend(onChange),
      );
      addTearDown(controller.dispose);

      controller.enter();

      expect(controller.isFullscreen.value, isFalse);
    });

    test('the notifier follows backend events', () {
      late _FakeBackend backend;
      final controller = FullscreenController(
        backendFactory: (onChange) => backend = _FakeBackend(onChange),
      );
      addTearDown(controller.dispose);

      backend.report(true);
      expect(controller.isFullscreen.value, isTrue);

      backend.report(false);
      expect(controller.isFullscreen.value, isFalse);
    });

    test(
        'toggle reads observed state, so a system-gesture exit that the '
        'backend reported means the next tap enters rather than exits', () {
      late _FakeBackend backend;
      final controller = FullscreenController(
        backendFactory: (onChange) => backend = _FakeBackend(onChange),
      );
      addTearDown(controller.dispose);

      controller.toggle();
      backend.report(true);
      backend.report(false); // viewer pressed Apple's Done button

      controller.toggle();

      expect(backend.enterCalls, 2);
      expect(backend.exitCalls, 0);
    });

    test('available is false only in unsupported mode', () {
      final unsupported = FullscreenController(
        backendFactory: (onChange) =>
            _FakeBackend(onChange, mode: FullscreenMode.unsupported),
      );
      addTearDown(unsupported.dispose);
      final supported = FullscreenController(
        backendFactory: (onChange) =>
            _FakeBackend(onChange, mode: FullscreenMode.nativeVideoElement),
      );
      addTearDown(supported.dispose);

      expect(unsupported.available, isFalse);
      expect(supported.available, isTrue);
    });

    test('dispose forwards to the backend', () {
      late _FakeBackend backend;
      final controller = FullscreenController(
        backendFactory: (onChange) => backend = _FakeBackend(onChange),
      );

      controller.dispose();

      expect(backend.disposed, isTrue);
    });

    test('an injected notifier is not disposed by the controller', () {
      final state = ValueNotifier<bool>(false);
      final controller = FullscreenController(
        backendFactory: (onChange) => _FakeBackend(onChange),
        state: state,
      );

      controller.dispose();

      // Would throw if the controller had disposed a notifier it does not own.
      expect(() => state.value = true, returnsNormally);
      state.dispose();
    });
  });
}

class _FakeBackend implements FullscreenBackend {
  _FakeBackend(this.onChange, {this.mode = FullscreenMode.osWindow});

  final ValueChanged<bool> onChange;

  @override
  final FullscreenMode mode;

  int enterCalls = 0;
  int exitCalls = 0;
  bool disposed = false;

  void report(bool value) => onChange(value);

  @override
  void attach(Player player) {}

  @override
  void enter() => enterCalls++;

  @override
  void exit() => exitCalls++;

  @override
  void dispose() => disposed = true;
}

/// Accepts every request and reports nothing, like `requestFullscreen` failing
/// on iPhone Safari inside media_kit's swallowing try/catch.
class _SilentBackend extends _FakeBackend {
  _SilentBackend(super.onChange);
}
