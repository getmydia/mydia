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
  }) build({
    Rect bounds = const Rect.fromLTWH(100, 100, 1200, 900),
    void Function()? onDetached,
  }) {
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
        onDetached: onDetached,
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

    test('attach pauses before it snapshots', () async {
      // Every other test awaits attach() to completion before probing
      // anything, so both orderings ("pause then snapshot" vs "snapshot then
      // pause") look identical afterwards. This test observes the paused
      // state at the exact moment the snapshot read happens, which is the
      // only place the ordering is externally visible: a resize event the
      // user already queued must not land after the snapshot is taken.
      final window = _PauseObservingWindowController(
        bounds: const Rect.fromLTWH(100, 100, 1200, 900),
      );
      final geometry = WindowGeometryController(
        window: window,
        store: InMemoryWindowGeometryStore(),
        readWorkAreas: oneDisplay,
        debounce: const Duration(milliseconds: 10),
      );
      window.geometry = geometry;
      addTearDown(geometry.dispose);

      final sizer = NativePlayerWindowSizer(
        window: window,
        geometry: geometry,
        readWorkAreas: oneDisplay,
      );

      await sizer.attach();

      expect(
        window.pausedAtSnapshot,
        isTrue,
        reason: 'attach() must pause before reading the window bounds, or a '
            'resize event already queued by the user could land after the '
            'snapshot is taken',
      );
    });

    test('detach resumes persistence even when restoring the snapshot throws',
        () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.sizer.attach();
      t.window.setBoundsError = StateError('platform channel gone');

      await expectLater(t.sizer.detach(), completes);

      t.window.setBoundsError = null;
      t.window.bounds = const Rect.fromLTWH(70, 70, 1000, 700);
      t.geometry.onWindowResize();
      await settle();

      expect(
        t.store.get()!.bounds,
        const Rect.fromLTWH(70, 70, 1000, 700),
        reason: 'resume() must run even though setBounds threw, or '
            'persistence silently stops for the rest of the session',
      );
    });

    test('onDetached fires exactly once on detach', () async {
      var callCount = 0;
      final t = build(onDetached: () => callCount++);
      addTearDown(t.geometry.dispose);

      await t.sizer.attach();
      await t.sizer.detach();

      expect(callCount, 1);

      // A stray second detach() — e.g. a double dispose() — must not fire it
      // again, or the facade would double-remove the sizer from
      // windowManager's listener list.
      await t.sizer.detach();

      expect(callCount, 1);
    });

    test('onDetached fires even when restoring the snapshot throws', () async {
      // A leak that only happens on the error path is still a leak: the
      // facade's removeListener call must run regardless of whether
      // setBounds succeeded.
      var callCount = 0;
      final t = build(onDetached: () => callCount++);
      addTearDown(t.geometry.dispose);

      await t.sizer.attach();
      t.window.setBoundsError = StateError('platform channel gone');

      await t.sizer.detach();

      expect(callCount, 1);
    });
  });

  group('aspect snapping', () {
    test('reshapes the window to a 16:9 video', () async {
      final t = build(bounds: const Rect.fromLTWH(100, 100, 1200, 900));
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await t.sizer.attach();
      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await settle();

      expect(t.window.bounds, const Rect.fromLTWH(100, 212.5, 1200, 675));
    });

    test('prefers the display size over the raw pixel size', () async {
      // Anamorphic DVD: 720x480 stored pixels displayed as 854x480.
      final t = build(bounds: const Rect.fromLTWH(0, 0, 1200, 900));
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await t.sizer.attach();
      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 720, h: 480, dw: 854, dh: 480));
      await settle();

      // 1200 / (854/480) = 674.5, not 1200 / 1.5 = 800.
      expect(t.window.bounds.height, closeTo(674.5, 0.5));
    });

    test('falls back to the raw size when no display size is given', () async {
      final t = build(bounds: const Rect.fromLTWH(0, 0, 1200, 900));
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await t.sizer.attach();
      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 1920, h: 1080));
      await settle();

      expect(t.window.bounds.height, closeTo(675, 0.5));
    });

    test('ignores params with no usable dimensions', () async {
      // Audio-only playback: this is the whole special case, and it is none.
      final t = build();
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await t.sizer.attach();
      t.window.setBoundsCalls.clear();
      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams());
      params.add(const VideoParams(w: 0, h: 0, dw: 0, dh: 0));
      await settle();

      expect(t.window.setBoundsCalls, isEmpty);
    });

    test('does not resize a maximized window', () async {
      final t = build();
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await t.sizer.attach();
      t.window.maximized = true;
      t.window.setBoundsCalls.clear();
      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await settle();

      expect(t.window.setBoundsCalls, isEmpty);
    });

    test('does not resize a fullscreen window', () async {
      final t = build();
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await t.sizer.attach();
      t.window.fullScreen = true;
      t.window.setBoundsCalls.clear();
      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await settle();

      expect(t.window.setBoundsCalls, isEmpty);
    });

    test('ignores a repeat of the aspect it already applied', () async {
      final t = build();
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await t.sizer.attach();
      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await settle();
      t.window.setBoundsCalls.clear();

      // A slightly different resolution whose aspect falls inside the 0.01
      // dedup threshold -- an HLS rendition switch, not a true shape change.
      // 1920/1080 = 1.7778, 1919/1080 = 1.7769: a 0.0009 difference.
      params.add(const VideoParams(w: 1919, h: 1080, dw: 1919, dh: 1080));
      await settle();

      expect(t.window.setBoundsCalls, isEmpty);
    });

    test('re-binding to a new player snaps to the new aspect', () async {
      // Next episode: _initializePlayer builds a fresh Player.
      final t = build(bounds: const Rect.fromLTWH(0, 0, 1200, 900));
      addTearDown(t.geometry.dispose);
      final first = StreamController<VideoParams>();
      final second = StreamController<VideoParams>();
      addTearDown(first.close);
      addTearDown(second.close);

      await t.sizer.attach();
      t.sizer.bindVideoParams(first.stream);
      first.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await settle();

      t.sizer.bindVideoParams(second.stream);
      second.add(const VideoParams(w: 1920, h: 800, dw: 1920, dh: 800));
      await settle();

      // 1200 / 2.4 = 500.
      expect(t.window.bounds.height, closeTo(500, 0.5));
    });

    test('the old subscription stops mattering after re-binding', () async {
      final t = build(bounds: const Rect.fromLTWH(0, 0, 1200, 900));
      addTearDown(t.geometry.dispose);
      final first = StreamController<VideoParams>();
      final second = StreamController<VideoParams>();
      addTearDown(first.close);
      addTearDown(second.close);

      await t.sizer.attach();
      t.sizer.bindVideoParams(first.stream);
      t.sizer.bindVideoParams(second.stream);
      t.window.setBoundsCalls.clear();

      first.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await settle();

      expect(t.window.setBoundsCalls, isEmpty);
    });

    test('binding before attach never resizes', () async {
      final t = build();
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await settle();

      expect(t.window.setBoundsCalls, isEmpty);
    });
  });

  group('manual resize', () {
    test('a user resize stops all later snapping', () async {
      final t = build(bounds: const Rect.fromLTWH(0, 0, 1200, 900));
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await t.sizer.attach();
      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await settle();

      // The user drags an edge.
      t.window.bounds = const Rect.fromLTWH(0, 0, 800, 600);
      t.sizer.onWindowResize();
      t.window.setBoundsCalls.clear();

      params.add(const VideoParams(w: 1920, h: 800, dw: 1920, dh: 800));
      await settle();

      expect(t.window.setBoundsCalls, isEmpty);
    });

    test('the sizer does not mistake its own resize for the user', () async {
      final t = build(bounds: const Rect.fromLTWH(0, 0, 1200, 900));
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await t.sizer.attach();
      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await settle();

      // The platform echoes our own resize back at us.
      t.sizer.onWindowResize();
      t.window.setBoundsCalls.clear();

      params.add(const VideoParams(w: 1920, h: 800, dw: 1920, dh: 800));
      await settle();

      expect(t.window.setBoundsCalls, hasLength(1));
    });

    test('a sub-pixel rounding difference is not a user resize', () async {
      final t = build(bounds: const Rect.fromLTWH(0, 0, 1200, 900));
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await t.sizer.attach();
      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await settle();

      // The platform applied 675.4 where we asked for 675.
      t.window.bounds = Rect.fromLTWH(
        t.window.bounds.left,
        t.window.bounds.top,
        t.window.bounds.width,
        t.window.bounds.height + 0.4,
      );
      t.sizer.onWindowResize();
      t.window.setBoundsCalls.clear();

      params.add(const VideoParams(w: 1920, h: 800, dw: 1920, dh: 800));
      await settle();

      expect(t.window.setBoundsCalls, hasLength(1));
    });

    test('a user resize before any snap also stops snapping', () async {
      final t = build(bounds: const Rect.fromLTWH(0, 0, 1200, 900));
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await t.sizer.attach();
      t.window.bounds = const Rect.fromLTWH(0, 0, 800, 600);
      t.sizer.onWindowResize();

      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await settle();

      expect(t.window.setBoundsCalls, isEmpty);
    });

    test('a fresh attach forgets the previous manual resize', () async {
      // The flag is per player session, so opening the player again starts
      // from a clean slate.
      final t = build(bounds: const Rect.fromLTWH(0, 0, 1200, 900));
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await t.sizer.attach();
      t.window.bounds = const Rect.fromLTWH(0, 0, 800, 600);
      t.sizer.onWindowResize();
      await t.sizer.detach();

      await t.sizer.attach();
      t.window.setBoundsCalls.clear();
      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await settle();

      expect(t.window.setBoundsCalls, hasLength(1));
    });

    test('a user resize that lands mid-snap still stops the snap', () async {
      // `_onVideoParams` checks `_userResized` once at the top, then awaits
      // isMaximized(), isFullScreen(), getBounds(), and readWorkAreas()
      // before calling setBounds(). If the user grabs an edge during one of
      // those round trips, `_checkForUserResize` latches `_userResized` --
      // but only a re-check right before the write stops the in-flight snap
      // from stomping it anyway.
      final window = _SlowFullScreenCheckController(
        bounds: const Rect.fromLTWH(0, 0, 1200, 900),
        delay: const Duration(milliseconds: 30),
      );
      final geometry = WindowGeometryController(
        window: window,
        store: InMemoryWindowGeometryStore(),
        readWorkAreas: oneDisplay,
        debounce: const Duration(milliseconds: 10),
      );
      addTearDown(geometry.dispose);
      final sizer = NativePlayerWindowSizer(
        window: window,
        geometry: geometry,
        readWorkAreas: oneDisplay,
      );
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await sizer.attach();
      sizer.bindVideoParams(params.stream);
      // No snap has happened yet, so this suspends on the slow
      // isFullScreen() check with `_expectedBounds` still null.
      params.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));

      // While that check is in flight, the user grabs an edge. With
      // `_expectedBounds` still null, `_checkForUserResize` latches
      // `_userResized` as soon as its own (fast) getBounds() resolves --
      // well before the 30ms delay above elapses.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      sizer.onWindowResize();

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(window.setBoundsCalls, isEmpty);
    });
  });

  group('fullscreen exit race', () {
    test(
        'a leave-fullscreen event after detach restores the snapshot and '
        'resumes geometry', () async {
      // Regression for the fullscreen-exit race: `isFullScreen()` still
      // reports true when `detach()` first checks it, because
      // `defaultExitNativeFullscreen()`'s animated exit has not finished.
      // `detach()` must wait for the real exit before deciding anything.
      final t = build(bounds: const Rect.fromLTWH(100, 100, 1200, 900));
      addTearDown(t.geometry.dispose);

      await t.sizer.attach();
      // Stand in for whatever the aspect snap did.
      await t.window.setBounds(const Rect.fromLTWH(0, 0, 2000, 838));
      t.window.fullScreen = true;

      // detach() must return promptly even though the window is still
      // reported fullscreen -- it must not block on the exit. It resolves
      // as soon as it hands off to the fullscreen wait, well before that
      // wait itself is done, so awaiting it here proves promptness without
      // proving anything about the restore yet.
      await t.sizer.detach();
      expect(
        t.window.bounds,
        const Rect.fromLTWH(0, 0, 2000, 838),
        reason: 'nothing must be restored until the real exit is observed',
      );

      // The OS finishes the animated exit.
      t.window.fullScreen = false;
      t.sizer.onWindowLeaveFullScreen();
      await settle();

      expect(t.window.bounds, const Rect.fromLTWH(100, 100, 1200, 900));

      // Geometry persistence must be resumed too.
      t.window.bounds = const Rect.fromLTWH(50, 50, 1000, 700);
      t.geometry.onWindowResize();
      await settle();
      expect(t.store.get()!.bounds, const Rect.fromLTWH(50, 50, 1000, 700));
    });

    test('the timeout also restores the snapshot and resumes geometry',
        () async {
      // If the leave-fullscreen event never arrives (window destroyed
      // mid-animation, or a platform quirk), the wait must not stall
      // forever -- a bounded timeout completes detach() anyway.
      final window = FakeWindowController(
        bounds: const Rect.fromLTWH(100, 100, 1200, 900),
      );
      final store = InMemoryWindowGeometryStore();
      final geometry = WindowGeometryController(
        window: window,
        store: store,
        readWorkAreas: oneDisplay,
        debounce: const Duration(milliseconds: 10),
      );
      addTearDown(geometry.dispose);
      final sizer = NativePlayerWindowSizer(
        window: window,
        geometry: geometry,
        readWorkAreas: oneDisplay,
        fullscreenExitTimeout: const Duration(milliseconds: 20),
      );

      await sizer.attach();
      await window.setBounds(const Rect.fromLTWH(0, 0, 2000, 838));
      window.fullScreen = true;

      await sizer.detach();
      // No onWindowLeaveFullScreen() call: only the timeout can complete
      // this. The window also happens to still report fullscreen once the
      // timeout fires, so nothing should be restored.
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(
        window.bounds,
        const Rect.fromLTWH(0, 0, 2000, 838),
        reason: 'still fullscreen when the timeout fired -- restoring would '
            'fight that state',
      );

      window.fullScreen = false;
      window.bounds = const Rect.fromLTWH(60, 60, 1000, 700);
      geometry.onWindowResize();
      await settle();

      expect(
        store.get()!.bounds,
        const Rect.fromLTWH(60, 60, 1000, 700),
        reason: 'the timeout path must resume geometry persistence just '
            'like the event path does',
      );
    });
  });
}

/// Records whether the geometry controller was already paused at the moment
/// attach() read the window bounds. [geometry] is assigned after
/// construction because it needs this very controller to build.
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

/// Gives `isFullScreen()` real, awaitable latency, standing in for a real
/// platform channel's millisecond-scale IPC. Used to prove that a user
/// resize landing while `_onVideoParams` is mid-flight still stops the snap.
class _SlowFullScreenCheckController extends FakeWindowController {
  _SlowFullScreenCheckController({required super.bounds, required this.delay});

  final Duration delay;

  @override
  Future<bool> isFullScreen() async {
    await Future<void>.delayed(delay);
    return super.isFullScreen();
  }
}
