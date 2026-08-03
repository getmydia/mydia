import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'player_window_sizer.dart';
import 'window_controller.dart';
import 'window_geometry_controller.dart';
import 'window_geometry_math.dart';

/// How far the applied rect may drift from the requested one before we call it
/// a user resize. Platforms round and constrain what they actually apply, so
/// exact equality would report a manual resize on every snap.
const double _kResizeTolerance = 2;

/// Snaps the window to the video's aspect ratio while the player is mounted.
///
/// Nothing here is allowed to throw: it runs from `PlayerScreen.initState` and
/// `dispose`, where an exception would surface as a red screen mid-playback.
class NativePlayerWindowSizer with WindowListener implements PlayerWindowSizer {
  final WindowController _window;
  final WindowGeometryController _geometry;
  final WorkAreaReader _readWorkAreas;

  /// How long [detach] waits for `onWindowLeaveFullScreen` before giving up
  /// and completing anyway. Exposed for tests, which inject a short value so
  /// they don't have to wait out the real default. See [detach].
  final Duration _fullscreenExitTimeout;

  /// Invoked once at the end of [detach], after the controller is resumed.
  /// The facade uses this to unregister the sizer from `windowManager`'s
  /// listener list — the sizer itself must never touch that singleton, and a
  /// sizer is built per player session, so without this every session would
  /// leak a listener.
  final void Function()? _onDetached;

  /// The window as it was before the player took over. Restored on detach.
  Rect? _snapshot;
  bool _attached = false;

  /// The token [WindowGeometryController.pause] returned on [attach], passed
  /// back to [WindowGeometryController.resume] on [detach] so a stale
  /// resume from a different sizer instance can never un-pause a controller
  /// this one still owns.
  Object? _geometryOwner;

  /// Set while [detach] is waiting for the OS to actually finish leaving
  /// fullscreen. See [detach] and [onWindowLeaveFullScreen].
  Completer<void>? _fullscreenExitSignal;

  StreamSubscription<VideoParams>? _paramsSubscription;

  /// The aspect currently applied, so a re-emitted or rendition-switched
  /// stream does not cause a second identical resize.
  double? _appliedAspect;

  /// The rect most recently asked for, so a resize event that does not match
  /// it can be attributed to the user.
  Rect? _expectedBounds;

  /// Set once the user resizes the window by hand. Stops all further snapping
  /// for this player session, including auto-played next episodes.
  bool _userResized = false;

  /// Guards [_onDetached] so a stray second [detach] call cannot fire it —
  /// and by extension cannot double-remove this sizer from a listener list —
  /// twice.
  bool _detachNotified = false;

  NativePlayerWindowSizer({
    required WindowController window,
    required WindowGeometryController geometry,
    required WorkAreaReader readWorkAreas,
    void Function()? onDetached,
    Duration fullscreenExitTimeout = const Duration(seconds: 2),
  })  : _window = window,
        _geometry = geometry,
        _readWorkAreas = readWorkAreas,
        _onDetached = onDetached,
        _fullscreenExitTimeout = fullscreenExitTimeout;

  @override
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    _userResized = false;
    _expectedBounds = null;
    _appliedAspect = null;
    // Pause first: a resize event already queued by the user must not land
    // after we start reshaping the window.
    _geometryOwner = _geometry.pause();

    try {
      _snapshot = await _window.getBounds();
    } catch (e) {
      debugPrint('[PlayerWindowSizer] Failed to snapshot window bounds: $e');
    }
  }

  @override
  void bindVideoParams(Stream<VideoParams> params) {
    unawaited(_paramsSubscription?.cancel());
    _paramsSubscription = params.listen(
      (p) => unawaited(_onVideoParams(p)),
      onError: (Object e) =>
          debugPrint('[PlayerWindowSizer] Video params stream error: $e'),
    );
  }

  Future<void> _onVideoParams(VideoParams params) async {
    if (!_attached || _userResized) return;

    final aspect = _aspectOf(params);
    if (aspect == null) return;

    // An HLS rendition switch re-emits the same shape at a new resolution.
    if (_appliedAspect != null && (_appliedAspect! - aspect).abs() < 0.01) {
      return;
    }

    try {
      // Maximized and fullscreen are explicit user states we do not override.
      if (await _window.isMaximized() || await _window.isFullScreen()) return;

      final current = await _window.getBounds();
      final area = areaContaining(current, await _readWorkAreas());
      if (area == null) return;

      final target = fitToAspect(
        current: current,
        aspect: aspect,
        workArea: area.bounds,
      );

      // The checks above are four awaits deep. If the user grabbed an edge
      // while they were in flight, `_checkForUserResize` (driven by the
      // resize event that generates) already latched `_userResized` for
      // it -- but only this re-check, right before the write, stops that
      // in-flight snap from stomping it anyway.
      if (_userResized) return;

      _appliedAspect = aspect;
      _expectedBounds = target;
      await _window.setBounds(target);
    } catch (e) {
      debugPrint('[PlayerWindowSizer] Failed to fit window to video: $e');
    }
  }

  @override
  void onWindowResize() => _noticeResize();

  // macOS and Windows also emit the "finished" variant; Linux does not. Both
  // route to the same check, and a duplicate is harmless.
  @override
  void onWindowResized() => _noticeResize();

  void _noticeResize() {
    if (!_attached || _userResized) return;
    unawaited(_checkForUserResize());
  }

  // Signals a `detach()` that is waiting out a fullscreen exit. See
  // `detach()` for why the wait exists at all: media_kit's
  // `defaultExitNativeFullscreen()` starts an animated, multi-hundred-ms
  // exit on macOS and returns before it finishes, so `isFullScreen()` at the
  // top of `detach()` still reports true. Harmless to fire with no `detach()`
  // waiting -- the completer is simply discarded.
  @override
  void onWindowLeaveFullScreen() {
    final signal = _fullscreenExitSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  Future<void> _checkForUserResize() async {
    try {
      final actual = await _window.getBounds();
      final expected = _expectedBounds;

      // No snap has happened yet, so any resize is the user's.
      if (expected == null) {
        _userResized = true;
        return;
      }

      final drifted =
          (actual.width - expected.width).abs() > _kResizeTolerance ||
              (actual.height - expected.height).abs() > _kResizeTolerance;
      if (drifted) _userResized = true;
    } catch (e) {
      debugPrint('[PlayerWindowSizer] Failed to inspect window bounds: $e');
    }
  }

  /// `dw`/`dh` is mpv's display size, already corrected for anamorphic pixels
  /// and rotation metadata, so it wins. Null or non-positive dimensions yield
  /// null, which is why audio-only content never triggers a resize.
  static double? _aspectOf(VideoParams params) {
    final dw = params.dw;
    final dh = params.dh;
    if (dw != null && dh != null && dw > 0 && dh > 0) return dw / dh;

    final w = params.w;
    final h = params.h;
    if (w != null && h != null && w > 0 && h > 0) return w / h;

    final aspect = params.aspect;
    if (aspect != null && aspect > 0) return aspect;

    return null;
  }

  @override
  Future<void> detach() async {
    unawaited(_paramsSubscription?.cancel());
    _paramsSubscription = null;

    final snapshot = _snapshot;
    _snapshot = null;
    _attached = false;
    _appliedAspect = null;

    var fullscreen = false;
    try {
      fullscreen = await _window.isFullScreen();
    } catch (e) {
      debugPrint(
          '[PlayerWindowSizer] Failed to check fullscreen state on detach: $e');
    }

    if (fullscreen) {
      // `PlayerScreen.dispose()` calls `defaultExitNativeFullscreen()` just
      // before this. On macOS that starts an animated, multi-hundred-ms
      // exit and returns immediately, so the check above still sees the old
      // state. Deciding anything now -- restoring the snapshot, or resuming
      // geometry persistence -- would let the animation's own resize
      // events, and a spurious `unmaximize` it also emits, land as the
      // window's saved geometry once the OS actually restores the
      // pre-fullscreen (letterboxed) frame. Wait for the real exit instead,
      // bounded by a timeout so the controller can never stay paused
      // forever if the event never arrives (e.g. the window was destroyed
      // mid-animation).
      unawaited(_awaitFullscreenExitThenComplete(snapshot));
      return;
    }

    await _completeDetach(snapshot);
  }

  /// Waits for [onWindowLeaveFullScreen], or [_fullscreenExitTimeout],
  /// whichever comes first, then runs [_completeDetach].
  Future<void> _awaitFullscreenExitThenComplete(Rect? snapshot) async {
    final signal = Completer<void>();
    _fullscreenExitSignal = signal;

    try {
      await Future.any<void>([
        signal.future,
        Future<void>.delayed(_fullscreenExitTimeout),
      ]);
    } finally {
      if (identical(_fullscreenExitSignal, signal)) {
        _fullscreenExitSignal = null;
      }
    }

    await _completeDetach(snapshot);
  }

  /// The shared tail of [detach]: restore [snapshot] if the window is
  /// neither maximized nor fullscreen *right now* (re-checked fresh, since
  /// this may run well after [detach] itself returned), resume geometry
  /// persistence, and fire [_onDetached] -- exactly once, on every path.
  Future<void> _completeDetach(Rect? snapshot) async {
    try {
      // Maximizing or going fullscreen during playback is an explicit
      // choice. Restoring an old rect would fight it.
      final untouchable =
          await _window.isMaximized() || await _window.isFullScreen();
      if (snapshot != null && !untouchable) {
        await _window.setBounds(snapshot);
      }
    } catch (e) {
      debugPrint('[PlayerWindowSizer] Failed to restore window bounds: $e');
    } finally {
      // Always, on every path: leaving the controller paused would silently
      // stop persisting geometry for the rest of the session.
      _geometry.resume(_geometryOwner);
    }

    if (!_detachNotified) {
      _detachNotified = true;
      _onDetached?.call();
    }
  }
}
