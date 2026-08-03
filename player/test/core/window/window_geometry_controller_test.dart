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
