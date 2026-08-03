import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/window/player_window_sizer.dart';
import 'package:player/core/window/player_window_sizer_native.dart';
import 'package:player/core/window/window_geometry_controller.dart';
import 'package:player/core/window/window_geometry_math.dart';
import 'package:player/core/window/window_geometry_store.dart';

import 'fake_window_controller.dart';

void main() {
  const primary = WorkArea(
    bounds: Rect.fromLTWH(0, 0, 2560, 1400),
    isPrimary: true,
  );

  Future<List<WorkArea>> oneDisplay() async => const [primary];

  ({
    NativePlayerWindowSizer sizer,
    FakeWindowController window,
    WindowGeometryController geometry,
    InMemoryWindowGeometryStore store,
  }) build({Rect bounds = const Rect.fromLTWH(100, 100, 1200, 900)}) {
    final window = FakeWindowController(bounds: bounds);
    final store = InMemoryWindowGeometryStore();
    final geometry = WindowGeometryController(
      window: window,
      store: store,
      readWorkAreas: oneDisplay,
      debounce: const Duration(milliseconds: 10),
    );
    return (
      sizer: NativePlayerWindowSizer(
        window: window,
        geometry: geometry,
        readWorkAreas: oneDisplay,
      ),
      window: window,
      geometry: geometry,
      store: store,
    );
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 40));

  group('NoopPlayerWindowSizer', () {
    test('every method is safe to call', () async {
      const sizer = NoopPlayerWindowSizer();
      final params = StreamController<VideoParams>();
      // NoopPlayerWindowSizer.bindVideoParams never listens (it's a permanent
      // no-op), and a single-subscription StreamController's close() future
      // never completes without a listener — give it one so the teardown
      // below doesn't hang.
      final paramsSubscription = params.stream.listen((_) {});
      addTearDown(paramsSubscription.cancel);
      addTearDown(params.close);

      await expectLater(sizer.attach(), completes);
      expect(() => sizer.bindVideoParams(params.stream), returnsNormally);
      await expectLater(sizer.detach(), completes);
    });
  });

  group('attach and detach', () {
    test('attaching stops geometry from being persisted', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.sizer.attach();
      t.geometry.onWindowResize();
      await settle();

      expect(t.store.get(), isNull);
    });

    test('detaching restores the bounds captured on attach', () async {
      final t = build(bounds: const Rect.fromLTWH(100, 100, 1200, 900));
      addTearDown(t.geometry.dispose);

      await t.sizer.attach();
      // Stand in for whatever the aspect snap did.
      await t.window.setBounds(const Rect.fromLTWH(0, 0, 2000, 838));
      await t.sizer.detach();

      expect(t.window.bounds, const Rect.fromLTWH(100, 100, 1200, 900));
    });

    test('detaching resumes persistence', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.sizer.attach();
      await t.sizer.detach();

      t.window.bounds = const Rect.fromLTWH(50, 50, 1000, 700);
      t.geometry.onWindowResize();
      await settle();

      expect(t.store.get()!.bounds, const Rect.fromLTWH(50, 50, 1000, 700));
    });

    test('detaching while maximized leaves the window alone', () async {
      // The user maximized during playback. Restoring an old rect would fight
      // an explicit choice.
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.sizer.attach();
      t.window.maximized = true;
      t.window.setBoundsCalls.clear();

      await t.sizer.detach();

      expect(t.window.setBoundsCalls, isEmpty);
    });

    test('detaching while maximized still resumes persistence', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.sizer.attach();
      t.window.maximized = true;
      await t.sizer.detach();

      t.window.maximized = false;
      t.window.bounds = const Rect.fromLTWH(60, 60, 1000, 700);
      t.geometry.onWindowResize();
      await settle();

      expect(t.store.get()!.bounds, const Rect.fromLTWH(60, 60, 1000, 700));
    });

    test('detaching while fullscreen leaves the window alone', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.sizer.attach();
      t.window.fullScreen = true;
      t.window.setBoundsCalls.clear();

      await t.sizer.detach();

      expect(t.window.setBoundsCalls, isEmpty);
    });

    test('detaching without attaching does not throw', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await expectLater(t.sizer.detach(), completes);
    });
  });
}
