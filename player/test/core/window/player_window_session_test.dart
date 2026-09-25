import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/player_window_session.dart';
import 'package:player/core/window/window_geometry_controller.dart';
import 'package:player/core/window/window_geometry_math.dart';
import 'package:player/core/window/window_geometry_store.dart';

import 'fake_window_controller.dart';
import 'manual_frames.dart';

void main() {
  const browse = Rect.fromLTWH(100, 100, 1200, 900);
  const playing = Rect.fromLTWH(0, 0, 2000, 838);

  Future<List<WorkArea>> oneDisplay() async => const [
        WorkArea(bounds: Rect.fromLTWH(0, 0, 2560, 1400), isPrimary: true),
      ];

  ({
    PlayerWindowSession session,
    FakeWindowController window,
    WindowGeometryController geometry,
    InMemoryWindowGeometryStore store,
    ManualFrames frames,
  }) build({
    Rect bounds = browse,
    Duration fullscreenExitTimeout = const Duration(seconds: 2),
  }) {
    final window = FakeWindowController(bounds: bounds);
    final store = InMemoryWindowGeometryStore();
    final geometry = WindowGeometryController(
      window: window,
      store: store,
      readWorkAreas: oneDisplay,
      debounce: const Duration(milliseconds: 10),
    );
    final frames = ManualFrames();
    return (
      session: PlayerWindowSession(
        window: window,
        geometry: geometry,
        afterFrame: frames.schedule,
        fullscreenExitTimeout: fullscreenExitTimeout,
      ),
      window: window,
      geometry: geometry,
      store: store,
      frames: frames,
    );
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 40));

  /// Whether a resize reaches the store, i.e. persistence is not paused.
  Future<bool> persists(
    FakeWindowController window,
    WindowGeometryController geometry,
    InMemoryWindowGeometryStore store,
  ) async {
    const probe = Rect.fromLTWH(33, 33, 1001, 701);
    window.bounds = probe;
    geometry.onWindowResize();
    await settle();
    return store.get()?.bounds == probe;
  }

  group('a single player', () {
    test('joining pauses persistence', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.session.join('a');

      expect(t.geometry.isPaused, isTrue);
      expect(t.session.isLive, isTrue);
    });

    test('joining pauses before it snapshots', () async {
      // A resize event the user already queued must not land after the
      // snapshot is taken.
      final window = _PauseObservingWindowController(bounds: browse);
      final geometry = WindowGeometryController(
        window: window,
        store: InMemoryWindowGeometryStore(),
        readWorkAreas: oneDisplay,
        debounce: const Duration(milliseconds: 10),
      );
      window.geometry = geometry;
      addTearDown(geometry.dispose);
      final session = PlayerWindowSession(
        window: window,
        geometry: geometry,
        afterFrame: ManualFrames().schedule,
      );

      await session.join('a');

      expect(window.pausedAtSnapshot, isTrue);
    });

    test('leaving restores nothing until the frame ends', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.session.join('a');
      await t.window.setBounds(playing);
      t.session.leave('a');
      await pumpEventQueue();

      expect(t.window.bounds, playing);
    });

    test('leaving restores the browse window after the frame', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.session.join('a');
      await t.window.setBounds(playing);
      t.session.leave('a');
      await t.frames.end();

      expect(t.window.bounds, browse);
      expect(t.session.isLive, isFalse);
    });

    test('the restore clears the aspect lock before resizing', () async {
      // GTK applies geometry hints to programmatic resizes too: a lock left
      // on would bend the browse rect.
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.session.join('a');
      await t.window.setAspectRatio(16 / 9);
      await t.window.setBounds(playing);
      t.window.callLog.clear();
      t.session.leave('a');
      await t.frames.end();

      expect(t.window.aspectRatio, 0);
      expect(t.window.callLog, ['setAspectRatio', 'setBounds']);
    });

    test('the restore resumes persistence', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.session.join('a');
      t.session.leave('a');
      await t.frames.end();

      expect(await persists(t.window, t.geometry, t.store), isTrue);
    });

    test('a maximized window is left alone but persistence resumes', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.session.join('a');
      t.window.maximized = true;
      t.window.setBoundsCalls.clear();
      t.session.leave('a');
      await t.frames.end();

      expect(t.window.setBoundsCalls, isEmpty);
      t.window.maximized = false;
      expect(await persists(t.window, t.geometry, t.store), isTrue);
    });

    test('persistence resumes even when the restore throws', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.session.join('a');
      t.window.setBoundsError = StateError('platform channel gone');
      t.session.leave('a');
      await t.frames.end();

      t.window.setBoundsError = null;
      expect(await persists(t.window, t.geometry, t.store), isTrue);
    });

    test('leaving without joining does nothing', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      t.session.leave('a');
      await t.frames.end();

      expect(t.window.setBoundsCalls, isEmpty);
    });
  });

  group('next-episode handoff', () {
    test('a player that joins before the old one leaves keeps the window',
        () async {
      // The order go_router actually produces: see
      // test/core/router/player_route_handoff_test.dart.
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.session.join('first');
      await t.window.setBounds(playing);
      await t.session.join('second');
      t.session.leave('first');
      await t.frames.end();

      expect(t.window.bounds, playing);
      expect(t.geometry.isPaused, isTrue);
    });

    test('a player that joins in the same frame the old one left keeps it',
        () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.session.join('first');
      await t.window.setBounds(playing);
      t.session.leave('first');
      await t.session.join('second');
      await t.frames.end();

      expect(t.window.bounds, playing);
      expect(t.geometry.isPaused, isTrue);
    });

    test('the last player out restores the original browse window', () async {
      // Not the first episode's player rect: the second player must not
      // re-snapshot.
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.session.join('first');
      await t.window.setBounds(playing);
      await t.session.join('second');
      t.session.leave('first');
      await t.frames.end();
      t.session.leave('second');
      await t.frames.end();

      expect(t.window.bounds, browse);
      expect(await persists(t.window, t.geometry, t.store), isTrue);
    });
  });

  group('fullscreen exit', () {
    test('waits for the real exit before restoring', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.session.join('a');
      await t.window.setBounds(playing);
      t.window.fullScreen = true;
      t.session.leave('a');
      await t.frames.end();

      expect(t.window.bounds, playing,
          reason: 'nothing is restored until the exit is observed');

      t.window.fullScreen = false;
      t.session.onWindowLeaveFullScreen();
      await settle();

      expect(t.window.bounds, browse);
      expect(await persists(t.window, t.geometry, t.store), isTrue);
    });

    test('the timeout resumes persistence without fighting fullscreen',
        () async {
      final t = build(fullscreenExitTimeout: const Duration(milliseconds: 20));
      addTearDown(t.geometry.dispose);

      await t.session.join('a');
      await t.window.setBounds(playing);
      t.window.fullScreen = true;
      t.session.leave('a');
      await t.frames.end();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(t.window.bounds, playing);
      t.window.fullScreen = false;
      expect(await persists(t.window, t.geometry, t.store), isTrue);
    });

    test('a player that joins during the wait cancels the restore', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.session.join('a');
      await t.window.setBounds(playing);
      t.window.fullScreen = true;
      t.session.leave('a');
      await t.frames.end();
      await t.session.join('b');
      t.window.fullScreen = false;
      t.session.onWindowLeaveFullScreen();
      await settle();

      expect(t.window.bounds, playing);
      expect(t.geometry.isPaused, isTrue);
    });
  });
}

/// Records whether persistence was already paused when the snapshot was read.
class _PauseObservingWindowController extends FakeWindowController {
  _PauseObservingWindowController({required super.bounds});

  WindowGeometryController? geometry;
  bool? pausedAtSnapshot;

  @override
  Future<Rect> getBounds() async {
    pausedAtSnapshot ??= geometry?.isPaused;
    return super.getBounds();
  }
}
