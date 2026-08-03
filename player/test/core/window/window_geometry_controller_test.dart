import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/window_geometry.dart';
import 'package:player/core/window/window_geometry_controller.dart';
import 'package:player/core/window/window_geometry_math.dart';
import 'package:player/core/window/window_geometry_store.dart';

import 'fake_window_controller.dart';

void main() {
  const primary = WorkArea(
    bounds: Rect.fromLTWH(0, 25, 1920, 1055),
    isPrimary: true,
  );

  Future<List<WorkArea>> oneDisplay() async => const [primary];
  Future<List<WorkArea>> noDisplays() async => const [];

  WindowGeometryController build({
    required FakeWindowController window,
    required WindowGeometryStore store,
    WorkAreaReader? readWorkAreas,
  }) =>
      WindowGeometryController(
        window: window,
        store: store,
        readWorkAreas: readWorkAreas ?? oneDisplay,
        debounce: const Duration(milliseconds: 10),
      );

  group('restore', () {
    test('applies the centered default when nothing is stored', () async {
      final window = FakeWindowController();
      await build(window: window, store: InMemoryWindowGeometryStore())
          .restore();

      expect(window.setBoundsCalls, [
        const Rect.fromLTWH(320, 152.5, 1280, 800),
      ]);
    });

    test('always sets the minimum size', () async {
      final window = FakeWindowController();
      await build(window: window, store: InMemoryWindowGeometryStore())
          .restore();

      expect(window.minimumSize, kMinWindowSize);
    });

    test('applies stored bounds', () async {
      final store = InMemoryWindowGeometryStore();
      await store.save(const WindowGeometry(
        bounds: Rect.fromLTWH(200, 100, 1400, 900),
        maximized: false,
      ));
      final window = FakeWindowController();

      await build(window: window, store: store).restore();

      expect(window.setBoundsCalls, [const Rect.fromLTWH(200, 100, 1400, 900)]);
      expect(window.maximizeCalls, 0);
    });

    test('sets bounds before maximizing', () async {
      // Order matters: maximizing first would make the bounds the thing the
      // user sees on unmaximize, which is not what was stored.
      final store = InMemoryWindowGeometryStore();
      await store.save(const WindowGeometry(
        bounds: Rect.fromLTWH(200, 100, 1400, 900),
        maximized: true,
      ));
      final window = FakeWindowController();

      await build(window: window, store: store).restore();

      expect(window.setBoundsCalls, [const Rect.fromLTWH(200, 100, 1400, 900)]);
      expect(window.maximizeCalls, 1);
      expect(
        window.callLog,
        ['setMinimumSize', 'setBounds', 'maximize'],
        reason: 'maximizing first would make the maximized frame what the user '
            'sees on a later unmaximize, not the bounds that were stored',
      );
    });

    test('recovers bounds saved on a display that is now gone', () async {
      final store = InMemoryWindowGeometryStore();
      await store.save(const WindowGeometry(
        bounds: Rect.fromLTWH(2400, 100, 1200, 800),
        maximized: false,
      ));
      final window = FakeWindowController();

      await build(window: window, store: store).restore();

      expect(window.setBoundsCalls, [
        const Rect.fromLTWH(360, 152.5, 1200, 800),
      ]);
    });

    test('leaves the window alone when no displays are readable', () async {
      final window = FakeWindowController();

      await build(
        window: window,
        store: InMemoryWindowGeometryStore(),
        readWorkAreas: noDisplays,
      ).restore();

      expect(window.setBoundsCalls, isEmpty);
      expect(
        window.minimumSize,
        kMinWindowSize,
        reason: 'the minimum size does not depend on knowing the displays',
      );
    });

    test('does not throw when the window rejects every call', () async {
      await expectLater(
        build(
          window: _ThrowingWindowController(),
          store: InMemoryWindowGeometryStore(),
        ).restore(),
        completes,
      );
    });
  });

  // Comfortably longer than the 10ms debounce these tests inject.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 40));

  group('tracking', () {
    test('coalesces a burst of resize events into one save', () async {
      final window = FakeWindowController(
        bounds: const Rect.fromLTWH(10, 20, 900, 600),
      );
      final store = InMemoryWindowGeometryStore();
      final controller = build(window: window, store: store);
      addTearDown(controller.dispose);

      // A drag emits one of these per pixel.
      for (var i = 0; i < 50; i++) {
        controller.onWindowResize();
      }
      await settle();

      expect(store.get()!.bounds, const Rect.fromLTWH(10, 20, 900, 600));
    });

    test('saves after a move', () async {
      final window = FakeWindowController(
        bounds: const Rect.fromLTWH(300, 400, 900, 600),
      );
      final store = InMemoryWindowGeometryStore();
      final controller = build(window: window, store: store);
      addTearDown(controller.dispose);

      controller.onWindowMove();
      await settle();

      expect(store.get()!.bounds, const Rect.fromLTWH(300, 400, 900, 600));
    });

    test('maximizing records the flag and keeps the stored rect', () async {
      // The heart of it: getBounds() returns the maximized frame, so writing
      // it would destroy the user's real window size permanently.
      final window = FakeWindowController(
        bounds: const Rect.fromLTWH(100, 100, 900, 600),
      );
      final store = InMemoryWindowGeometryStore();
      final controller = build(window: window, store: store);
      addTearDown(controller.dispose);

      controller.onWindowResize();
      await settle();

      window.maximized = true;
      window.bounds = const Rect.fromLTWH(0, 25, 1920, 1055);
      controller.onWindowMaximize();
      await settle();

      expect(store.get()!.maximized, isTrue);
      expect(
        store.get()!.bounds,
        const Rect.fromLTWH(100, 100, 900, 600),
        reason: 'the un-maximized rect must survive being maximized',
      );
    });

    test('a resize while maximized still does not touch the rect', () async {
      final window = FakeWindowController(
        bounds: const Rect.fromLTWH(100, 100, 900, 600),
      );
      final store = InMemoryWindowGeometryStore();
      final controller = build(window: window, store: store);
      addTearDown(controller.dispose);

      controller.onWindowResize();
      await settle();

      window.maximized = true;
      window.bounds = const Rect.fromLTWH(0, 25, 1920, 1055);
      controller.onWindowResize();
      await settle();

      expect(store.get()!.bounds, const Rect.fromLTWH(100, 100, 900, 600));
    });

    test('unmaximizing writes the rect again', () async {
      final window = FakeWindowController(
        bounds: const Rect.fromLTWH(0, 25, 1920, 1055),
        maximized: true,
      );
      final store = InMemoryWindowGeometryStore();
      final controller = build(window: window, store: store);
      addTearDown(controller.dispose);

      controller.onWindowMaximize();
      await settle();

      window.maximized = false;
      window.bounds = const Rect.fromLTWH(100, 100, 900, 600);
      controller.onWindowUnmaximize();
      await settle();

      expect(store.get()!.maximized, isFalse);
      expect(store.get()!.bounds, const Rect.fromLTWH(100, 100, 900, 600));
    });

    test('writes nothing while fullscreen', () async {
      // Fullscreen bounds are the whole display, which is neither worth
      // storing nor safe to restore into.
      final window = FakeWindowController(fullScreen: true);
      final store = InMemoryWindowGeometryStore();
      final controller = build(window: window, store: store);
      addTearDown(controller.dispose);

      controller.onWindowResize();
      await settle();

      expect(store.get(), isNull);
    });

    test('reads and writes nothing while paused', () async {
      final window = FakeWindowController();
      final store = InMemoryWindowGeometryStore();
      final controller = build(window: window, store: store);
      addTearDown(controller.dispose);

      controller.pause();
      controller.onWindowResize();
      await settle();

      expect(store.get(), isNull);
    });

    test('pause cancels a change that was already pending', () async {
      // The player attaches mid-drag; the queued write must not land after
      // the player has already reshaped the window.
      final window = FakeWindowController();
      final store = InMemoryWindowGeometryStore();
      final controller = build(window: window, store: store);
      addTearDown(controller.dispose);

      controller.onWindowResize();
      controller.pause();
      await settle();

      expect(store.get(), isNull);
    });

    test('resume restores tracking', () async {
      final window = FakeWindowController(
        bounds: const Rect.fromLTWH(5, 5, 800, 500),
      );
      final store = InMemoryWindowGeometryStore();
      final controller = build(window: window, store: store);
      addTearDown(controller.dispose);

      controller.pause();
      controller.resume();
      controller.onWindowResize();
      await settle();

      expect(store.get()!.bounds, const Rect.fromLTWH(5, 5, 800, 500));
    });

    test('close writes the pending change without waiting', () async {
      final window = FakeWindowController(
        bounds: const Rect.fromLTWH(7, 7, 810, 510),
      );
      final store = InMemoryWindowGeometryStore();
      final controller = build(window: window, store: store);
      addTearDown(controller.dispose);

      controller.onWindowResize();
      await controller.flush();

      expect(store.get()!.bounds, const Rect.fromLTWH(7, 7, 810, 510));
    });

    test('dispose stops a pending write from landing', () async {
      final window = FakeWindowController();
      final store = InMemoryWindowGeometryStore();
      final controller = build(window: window, store: store);

      controller.onWindowResize();
      controller.dispose();
      await settle();

      expect(store.get(), isNull);
    });

    test('a failing window does not throw out of an event', () async {
      final controller = build(
        window: _ThrowingWindowController(),
        store: InMemoryWindowGeometryStore(),
      );
      addTearDown(controller.dispose);

      controller.onWindowResize();

      await expectLater(controller.flush(), completes);
    });
  });
}

/// Stands in for a platform channel that is not there — what
/// `flutter test` sees if anything reaches the real plugin.
class _ThrowingWindowController extends FakeWindowController {
  @override
  Future<Rect> getBounds() async => throw StateError('no platform channel');

  @override
  Future<void> setBounds(Rect bounds) async =>
      throw StateError('no platform channel');

  @override
  Future<void> setMinimumSize(Size size) async =>
      throw StateError('no platform channel');
}
