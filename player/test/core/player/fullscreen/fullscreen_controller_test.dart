// The controller's whole job is that its notifier reports observed state
// rather than requested state. Every test here is written against that: a
// backend that accepts a request but never reports must leave the notifier
// false, because that is precisely the bug this replaces — `PlayerScreen`
// used to flip `_isFullscreen` inside `setState` before asking the platform,
// so on iPhone Safari the icon said "exit fullscreen" over an inline video.
//
// `available` is held to the same standard. It used to be `mode != unsupported`,
// a capability probe read once at construction, so it stayed true while the web
// backend had nothing bound and while every request was being rejected. The
// button drawn from it was present and dead, which is the same lie one layer
// down.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/player/fullscreen/fullscreen_backend.dart';
import 'package:player/core/player/fullscreen/fullscreen_controller.dart';
import 'package:player/core/player/fullscreen/fullscreen_failure.dart';
import 'package:player/core/player/fullscreen/fullscreen_mode.dart';
import 'package:player/core/player/fullscreen/fullscreen_report.dart';

void main() {
  group('FullscreenController', () {
    test('starts windowed', () {
      final controller = FullscreenController(
        backendFactory: (onChange, onFailure) => _FakeBackend(onChange),
      );
      addTearDown(controller.dispose);

      expect(controller.isFullscreen.value, isFalse);
    });

    test('enter forwards to the backend', () {
      late _FakeBackend backend;
      final controller = FullscreenController(
        backendFactory: (onChange, onFailure) =>
            backend = _FakeBackend(onChange),
      );
      addTearDown(controller.dispose);

      controller.enter();

      expect(backend.enterCalls, 1);
    });

    test(
        'a backend that accepts the request but never reports leaves the '
        'notifier false — the iPhone Safari case', () {
      final controller = FullscreenController(
        backendFactory: (onChange, onFailure) => _SilentBackend(onChange),
      );
      addTearDown(controller.dispose);

      controller.enter();

      expect(controller.isFullscreen.value, isFalse);
    });

    test('the notifier follows backend events', () {
      late _FakeBackend backend;
      final controller = FullscreenController(
        backendFactory: (onChange, onFailure) =>
            backend = _FakeBackend(onChange),
      );
      addTearDown(controller.dispose);

      backend.emit(true);
      expect(controller.isFullscreen.value, isTrue);

      backend.emit(false);
      expect(controller.isFullscreen.value, isFalse);
    });

    test(
        'toggle reads observed state, so a system-gesture exit that the '
        'backend reported means the next tap enters rather than exits', () {
      late _FakeBackend backend;
      final controller = FullscreenController(
        backendFactory: (onChange, onFailure) =>
            backend = _FakeBackend(onChange),
      );
      addTearDown(controller.dispose);

      controller.toggle();
      backend.emit(true);
      backend.emit(false); // viewer pressed Apple's Done button

      controller.toggle();

      expect(backend.enterCalls, 2);
      expect(backend.exitCalls, 0);
    });

    test('available follows the backend, not the mode', () {
      final controller = FullscreenController(
        backendFactory: (onChange, onFailure) => _FakeBackend(
          onChange,
          mode: FullscreenMode.nativeVideoElement,
          ready: false,
        ),
      );
      addTearDown(controller.dispose);

      // A route exists. Nothing is bound to it, so the button must not draw.
      expect(controller.mode, FullscreenMode.nativeVideoElement);
      expect(controller.available.value, isFalse);
    });

    test('a readiness change notifies, so the button can appear', () {
      late _FakeBackend backend;
      final controller = FullscreenController(
        backendFactory: (onChange, onFailure) =>
            backend = _FakeBackend(onChange, ready: false),
      );
      addTearDown(controller.dispose);

      var notified = 0;
      controller.available.addListener(() => notified++);

      backend.setReady(true);

      expect(notified, 1);
      expect(controller.available.value, isTrue);
    });

    test('failures reach a listener without moving fullscreen state', () async {
      late _FakeBackend backend;
      final controller = FullscreenController(
        backendFactory: (onChange, onFailure) =>
            backend = _FakeBackend(onChange, onFailure: onFailure),
      );
      addTearDown(controller.dispose);

      final seen = <FullscreenFailure>[];
      final subscription = controller.failures.listen(seen.add);
      addTearDown(subscription.cancel);

      backend.fail(const FullscreenFailure(
        FullscreenFailureCause.documentRequestRejected,
        requestInitiated: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(1));
      expect(
        seen.single.cause,
        FullscreenFailureCause.documentRequestRejected,
      );
      expect(controller.isFullscreen.value, isFalse);
    });

    test('the report reflects the backend', () {
      final controller = FullscreenController(
        backendFactory: (onChange, onFailure) => _FakeBackend(
          onChange,
          mode: FullscreenMode.nativeVideoElement,
          ready: false,
        ),
      );
      addTearDown(controller.dispose);

      expect(controller.report.mode, FullscreenMode.nativeVideoElement);
      expect(controller.report.ready, isFalse);
    });

    test('dispose forwards to the backend', () {
      late _FakeBackend backend;
      final controller = FullscreenController(
        backendFactory: (onChange, onFailure) =>
            backend = _FakeBackend(onChange),
      );

      controller.dispose();

      expect(backend.disposed, isTrue);
    });

    test('an injected notifier is not disposed by the controller', () {
      final state = ValueNotifier<bool>(false);
      final controller = FullscreenController(
        backendFactory: (onChange, onFailure) => _FakeBackend(onChange),
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
  _FakeBackend(
    this.onChange, {
    this.mode = FullscreenMode.osWindow,
    bool ready = true,
    this.onFailure,
  }) : _ready = ValueNotifier<bool>(ready);

  final ValueChanged<bool> onChange;
  final FullscreenFailureSink? onFailure;

  @override
  final FullscreenMode mode;

  final ValueNotifier<bool> _ready;

  @override
  ValueListenable<bool> get ready => _ready;

  @override
  FullscreenReport get report =>
      FullscreenReport(mode: mode, ready: _ready.value);

  int enterCalls = 0;
  int exitCalls = 0;
  bool disposed = false;

  /// Reports a platform transition, the way a real backend does. Named `emit`
  /// rather than `report` because the interface now carries a `report` getter.
  void emit(bool value) => onChange(value);

  void setReady(bool value) => _ready.value = value;

  void fail(FullscreenFailure failure) => onFailure?.call(failure);

  @override
  void attach(Player player) {}

  @override
  void enter() => enterCalls++;

  @override
  void exit() => exitCalls++;

  @override
  void dispose() {
    disposed = true;
    _ready.dispose();
  }
}

/// Accepts every request and reports nothing, like `requestFullscreen` failing
/// on iPhone Safari inside media_kit's swallowing try/catch.
class _SilentBackend extends _FakeBackend {
  _SilentBackend(super.onChange);
}
