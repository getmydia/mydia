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
      final store = _CountingStore(InMemoryWindowGeometryStore());
      final controller = build(window: window, store: store);
      addTearDown(controller.dispose);

      // A drag emits one of these per pixel.
      for (var i = 0; i < 50; i++) {
        controller.onWindowResize();
      }
      await settle();

      expect(store.get()!.bounds, const Rect.fromLTWH(10, 20, 900, 600));
      expect(
        store.saveCount,
        1,
        reason: '50 debounced events must land as one write, not 50 '
            'identical ones',
      );
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

    test('a first-ever maximize never stores the maximized frame', () async {
      // Nothing persisted yet and the user maximizes. getBounds() returns the
      // maximized frame, so storing it would make the maximized size the thing
      // they see when they later unmaximize — the exact loss the maximized
      // branch exists to prevent. Record the centered default instead.
      final window = FakeWindowController(
        bounds: const Rect.fromLTWH(0, 25, 1920, 1055),
        maximized: true,
      );
      final store = InMemoryWindowGeometryStore();
      final controller = build(window: window, store: store);
      addTearDown(controller.dispose);

      controller.onWindowMaximize();
      await settle();

      expect(store.get()!.maximized, isTrue);
      expect(
        store.get()!.bounds,
        const Rect.fromLTWH(320, 152.5, 1280, 800),
        reason: 'should be the centered default, not the maximized frame',
      );
      expect(
        store.get()!.bounds,
        isNot(const Rect.fromLTWH(0, 25, 1920, 1055)),
        reason: 'storing the maximized frame is the bug this pins',
      );
    });

    test('a first-ever maximize with no readable display writes nothing',
        () async {
      // No display means no sensible rect to invent, and the flag alone is not
      // worth a fabricated size.
      final window = FakeWindowController(maximized: true);
      final store = InMemoryWindowGeometryStore();
      final controller = build(
        window: window,
        store: store,
        readWorkAreas: noDisplays,
      );
      addTearDown(controller.dispose);

      controller.onWindowMaximize();
      await settle();

      expect(store.get(), isNull);
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

    test('pause stops a save already in flight from landing', () async {
      // The player attaches mid-drag: pause() runs while a save from before
      // it attached is suspended on the platform channel. That save must not
      // persist once it resumes, even though its `if (_paused) return;` entry
      // guard already passed before pause() ran.
      final window = _SlowWindowController(
        bounds: const Rect.fromLTWH(50, 50, 900, 600),
        delay: const Duration(milliseconds: 30),
      );
      final store = InMemoryWindowGeometryStore();
      final controller = build(window: window, store: store);
      addTearDown(controller.dispose);

      controller.onWindowResize();
      // Let the 10ms debounce fire and _save() suspend on the slow
      // getBounds(), which will not resolve for another ~20ms.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      controller.pause();
      // Simulate the player reshaping the window during the pause.
      window.bounds = const Rect.fromLTWH(0, 0, 1920, 800);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(store.get(), isNull);
    });

    test('resume restores tracking', () async {
      final window = FakeWindowController(
        bounds: const Rect.fromLTWH(5, 5, 800, 500),
      );
      final store = InMemoryWindowGeometryStore();
      final controller = build(window: window, store: store);
      addTearDown(controller.dispose);

      final owner = controller.pause();
      controller.resume(owner);
      controller.onWindowResize();
      await settle();

      expect(store.get()!.bounds, const Rect.fromLTWH(5, 5, 800, 500));
    });

    test('a stale resume from a superseded owner does not un-pause it',
        () async {
      // Guards against a stale detach() (e.g. from a previous player
      // session) resuming a controller a *different*, still-live owner
      // paused after it.
      final window = FakeWindowController(
        bounds: const Rect.fromLTWH(5, 5, 800, 500),
      );
      final store = InMemoryWindowGeometryStore();
      final controller = build(window: window, store: store);
      addTearDown(controller.dispose);

      final firstOwner = controller.pause();
      controller.pause(); // A second owner takes over.

      controller.resume(firstOwner);
      controller.onWindowResize();
      await settle();

      expect(
        store.get(),
        isNull,
        reason: 'the second owner still holds the pause; a stale resume '
            'from the first owner must not un-pause it',
      );
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

/// Gives `getBounds()` real, awaitable latency — a real platform channel has
/// millisecond-scale IPC latency, unlike [FakeWindowController]'s
/// microtask-fast futures. Needed to prove `_save()` cannot resume after
/// [WindowGeometryController.pause] and still write.
class _SlowWindowController extends FakeWindowController {
  _SlowWindowController({required super.bounds, required this.delay});

  final Duration delay;

  @override
  Future<Rect> getBounds() async {
    await Future<void>.delayed(delay);
    return super.getBounds();
  }
}

/// Counts writes so a test can assert the debounce coalesces rather than
/// merely that the final stored value is right — 50 identical writes and one
/// write leave the same state behind.
class _CountingStore implements WindowGeometryStore {
  _CountingStore(this._inner);
  final WindowGeometryStore _inner;
  int saveCount = 0;

  @override
  WindowGeometry? get() => _inner.get();

  @override
  Future<void> save(WindowGeometry geometry) {
    saveCount++;
    return _inner.save(geometry);
  }
}
