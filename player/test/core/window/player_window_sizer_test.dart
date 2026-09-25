import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/window/player_window_session.dart';
import 'package:player/core/window/player_window_sizer.dart';
import 'package:player/core/window/player_window_sizer_native.dart';
import 'package:player/core/window/window_geometry_controller.dart';
import 'package:player/core/window/window_geometry_math.dart';
import 'package:player/core/window/window_geometry_store.dart';

import 'fake_window_controller.dart';
import 'manual_frames.dart';

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
    PlayerWindowSession session,
    ManualFrames frames,
  }) build({
    Rect bounds = const Rect.fromLTWH(100, 100, 1200, 900),
    void Function()? onDetached,
    FakeWindowController? windowOverride,
  }) {
    final window = windowOverride ?? FakeWindowController(bounds: bounds);
    final geometry = WindowGeometryController(
      window: window,
      store: InMemoryWindowGeometryStore(),
      readWorkAreas: oneDisplay,
      debounce: const Duration(milliseconds: 10),
    );
    final frames = ManualFrames();
    final session = PlayerWindowSession(
      window: window,
      geometry: geometry,
      afterFrame: frames.schedule,
    );
    return (
      sizer: NativePlayerWindowSizer(
        window: window,
        session: session,
        readWorkAreas: oneDisplay,
        onDetached: onDetached,
      ),
      window: window,
      geometry: geometry,
      session: session,
      frames: frames,
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
    test('attaching joins the session', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await t.sizer.attach();

      expect(t.session.isLive, isTrue);
      expect(t.geometry.isPaused, isTrue);
    });

    test('detaching leaves the session, which restores after the frame',
        () async {
      final t = build(bounds: const Rect.fromLTWH(100, 100, 1200, 900));
      addTearDown(t.geometry.dispose);

      await t.sizer.attach();
      await t.window.setBounds(const Rect.fromLTWH(0, 0, 2000, 838));
      await t.sizer.detach();
      await t.frames.end();

      expect(t.window.bounds, const Rect.fromLTWH(100, 100, 1200, 900));
      expect(t.session.isLive, isFalse);
    });

    test('detaching without attaching does not throw', () async {
      final t = build();
      addTearDown(t.geometry.dispose);

      await expectLater(t.sizer.detach(), completes);
    });

    test('onDetached fires exactly once', () async {
      var callCount = 0;
      final t = build(onDetached: () => callCount++);
      addTearDown(t.geometry.dispose);

      await t.sizer.attach();
      await t.sizer.detach();
      // A stray second detach(), e.g. a double dispose(), must not
      // double-remove the sizer from windowManager's listener list.
      await t.sizer.detach();

      expect(callCount, 1);
    });

    test('the next episode inherits the window, then refits its aspect',
        () async {
      // Two sizers on one session, in the order go_router produces.
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
      // The user makes it bigger.
      t.window.bounds = const Rect.fromLTWH(0, 0, 1600, 900);

      final next = NativePlayerWindowSizer(
        window: t.window,
        session: t.session,
        readWorkAreas: oneDisplay,
      );
      await next.attach();
      await t.sizer.detach();
      await t.frames.end();
      next.bindVideoParams(second.stream);
      second.add(const VideoParams(w: 1920, h: 800, dw: 1920, dh: 800));
      await settle();

      // Width kept at 1600; 1600 / 2.4 = 666.67.
      expect(t.window.bounds.width, 1600);
      expect(t.window.bounds.height, closeTo(666.67, 0.5));
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
    test('a user resize does not stop the next aspect from fitting', () async {
      final t = build(bounds: const Rect.fromLTWH(0, 0, 1200, 900));
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await t.sizer.attach();
      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await settle();

      t.window.bounds = const Rect.fromLTWH(0, 0, 1400, 788);
      t.sizer.onWindowResize();
      params.add(const VideoParams(w: 1920, h: 800, dw: 1920, dh: 800));
      await settle();

      expect(t.window.bounds.width, 1400);
      expect(t.window.bounds.height, closeTo(583.33, 0.5));
    });
  });

  group('aspect lock', () {
    Future<
        ({
          NativePlayerWindowSizer sizer,
          FakeWindowController window,
          WindowGeometryController geometry,
          PlayerWindowSession session,
          ManualFrames frames,
          StreamController<VideoParams> params,
        })> playing({
      Rect bounds = const Rect.fromLTWH(0, 0, 1200, 900),
      VideoParams video =
          const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080),
    }) async {
      final t = build(bounds: bounds);
      final params = StreamController<VideoParams>();
      addTearDown(t.geometry.dispose);
      addTearDown(params.close);
      await t.sizer.attach();
      t.sizer.bindVideoParams(params.stream);
      params.add(video);
      await settle();
      return (
        sizer: t.sizer,
        window: t.window,
        geometry: t.geometry,
        session: t.session,
        frames: t.frames,
        params: params,
      );
    }

    test('is set to the video aspect when the window is fitted', () async {
      final t = await playing();

      expect(t.window.aspectRatio, closeTo(16 / 9, 0.0001));
    });

    test('is set before the resize', () async {
      final t = build(bounds: const Rect.fromLTWH(0, 0, 1200, 900));
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await t.sizer.attach();
      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await settle();

      expect(t.window.callLog, ['setAspectRatio', 'setBounds']);
    });

    test('follows a new aspect', () async {
      final t = await playing();

      t.params.add(const VideoParams(w: 1920, h: 800, dw: 1920, dh: 800));
      await settle();

      expect(t.window.aspectRatio, closeTo(2.4, 0.0001));
    });

    test('is not set when the minimum size forces letterboxing', () async {
      // 720 wide at 2.39:1 would be 301 tall, under the 480 floor, so the
      // window is 720x480 and a 2.39 lock would fight the floor.
      final t = await playing(
        bounds: const Rect.fromLTWH(0, 0, 720, 480),
        video: const VideoParams(w: 1920, h: 803, dw: 1920, dh: 803),
      );

      expect(t.window.aspectRatio, 0);
    });

    test('is never set for audio-only content', () async {
      final t = await playing(video: const VideoParams());

      expect(t.window.setAspectRatioCalls, isEmpty);
    });

    test('is dropped on maximize and restored on unmaximize', () async {
      final t = await playing();

      t.sizer.onWindowMaximize();
      await pumpEventQueue();
      expect(t.window.aspectRatio, 0);

      t.sizer.onWindowUnmaximize();
      await pumpEventQueue();
      expect(t.window.aspectRatio, closeTo(16 / 9, 0.0001));
    });

    test('is dropped in fullscreen and restored on exit', () async {
      final t = await playing();

      t.sizer.onWindowEnterFullScreen();
      await pumpEventQueue();
      expect(t.window.aspectRatio, 0);

      t.sizer.onWindowLeaveFullScreen();
      await pumpEventQueue();
      expect(t.window.aspectRatio, closeTo(16 / 9, 0.0001));
    });

    test('is not re-applied once the sizer has detached', () async {
      final t = await playing();

      await t.sizer.detach();
      await t.frames.end();
      t.sizer.onWindowUnmaximize();
      await pumpEventQueue();

      expect(t.window.aspectRatio, 0);
    });

    test('a failing lock call does not stop the resize', () async {
      final t = build(bounds: const Rect.fromLTWH(0, 0, 1200, 900));
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);
      t.window.setAspectRatioError = StateError('not supported');

      await t.sizer.attach();
      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await settle();

      expect(t.window.bounds, const Rect.fromLTWH(0, 112.5, 1200, 675));
    });

    test(
        'a maximize that lands mid-fit leaves the window unlocked and '
        'untouched', () async {
      final window = _GatedBoundsWindowController(
        bounds: const Rect.fromLTWH(0, 0, 1200, 900),
      );
      final t = build(windowOverride: window);
      addTearDown(t.geometry.dispose);
      final params = StreamController<VideoParams>();
      addTearDown(params.close);

      await t.sizer.attach();
      window.armGate();
      t.sizer.bindVideoParams(params.stream);
      params.add(const VideoParams(w: 1920, h: 1080, dw: 1920, dh: 1080));
      await pumpEventQueue();

      window.maximized = true;
      t.sizer.onWindowMaximize();
      window.openGate();
      await settle();

      expect(window.setAspectRatioCalls, isEmpty);
      expect(window.setBoundsCalls, isEmpty);
    });
  });
}

/// A [FakeWindowController] whose [getBounds] parks on a gate the test
/// controls, so a test can land a window event exactly mid-fit -- after the
/// maximized/fullscreen check but before the target rect and lock are
/// applied. `attach()`'s `PlayerWindowSession.join` also calls `getBounds`,
/// so the gate starts open and must be armed explicitly.
class _GatedBoundsWindowController extends FakeWindowController {
  Completer<void>? _gate;

  _GatedBoundsWindowController({super.bounds});

  void armGate() => _gate = Completer<void>();

  void openGate() {
    final gate = _gate;
    _gate = null;
    gate?.complete();
  }

  @override
  Future<Rect> getBounds() async {
    final gate = _gate;
    if (gate != null) await gate.future;
    return super.getBounds();
  }
}
