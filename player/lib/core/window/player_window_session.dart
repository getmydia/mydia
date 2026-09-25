import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:window_manager/window_manager.dart';

import 'window_controller.dart';
import 'window_geometry_controller.dart';

/// Runs a callback once the current frame is done.
typedef AfterFrameScheduler = void Function(VoidCallback callback);

/// The production [AfterFrameScheduler]: a post-frame callback, plus a frame
/// request in case nothing else is about to draw one.
void runAfterCurrentFrame(VoidCallback callback) {
  SchedulerBinding.instance
    ..addPostFrameCallback((_) => callback())
    ..ensureVisualUpdate();
}

/// The window's time "in the player", which can span several player screens.
///
/// Next/previous episode navigation mounts a new `PlayerScreen` whose sizer
/// joins before the old screen's sizer leaves (see
/// `test/core/router/player_route_handoff_test.dart`). Holding the browse
/// snapshot and the geometry pause here, instead of in each sizer, is what
/// lets the second episode inherit the window the user had rather than the
/// browse rect.
///
/// The session ends only when the last member has left and a frame has
/// passed with nobody rejoining. Then it restores the browse window, drops
/// the aspect lock and resumes geometry persistence. Nothing here throws.
class PlayerWindowSession with WindowListener {
  final WindowController _window;
  final WindowGeometryController _geometry;
  final AfterFrameScheduler _afterFrame;

  /// How long the end of a session waits for `onWindowLeaveFullScreen`.
  /// media_kit's `defaultExitNativeFullscreen()` starts an animated exit on
  /// macOS and returns before it finishes, so `isFullScreen()` can still
  /// report true; restoring then would let the animation's own resize events
  /// land as the saved geometry.
  final Duration _fullscreenExitTimeout;

  final Set<Object> _members = {};
  bool _live = false;
  Rect? _snapshot;
  Object? _geometryOwner;

  /// Bumped on every join and leave, so a scheduled end can tell it has
  /// been overtaken.
  int _generation = 0;

  Completer<void>? _fullscreenExitSignal;

  PlayerWindowSession({
    required WindowController window,
    required WindowGeometryController geometry,
    AfterFrameScheduler afterFrame = runAfterCurrentFrame,
    Duration fullscreenExitTimeout = const Duration(seconds: 2),
  })  : _window = window,
        _geometry = geometry,
        _afterFrame = afterFrame,
        _fullscreenExitTimeout = fullscreenExitTimeout;

  bool get isLive => _live;

  /// Adds [member]. The first member of a new session pauses geometry
  /// persistence and snapshots the browse window; later ones inherit both.
  Future<void> join(Object member) async {
    _members.add(member);
    _generation++;
    if (_live) return;
    _live = true;

    // Pause first: a resize event already queued by the user must not land
    // after the snapshot.
    _geometryOwner = _geometry.pause();
    try {
      _snapshot = await _window.getBounds();
    } catch (e) {
      debugPrint('[PlayerWindowSession] Failed to snapshot window bounds: $e');
    }
  }

  /// Removes [member]. When nobody is left, schedules the end of the session
  /// for after the current frame.
  void leave(Object member) {
    if (!_members.remove(member)) return;
    if (_members.isNotEmpty || !_live) return;

    final generation = ++_generation;
    try {
      _afterFrame(() => unawaited(_endUnlessRejoined(generation)));
    } catch (e) {
      // No scheduler (no binding). End now rather than never.
      debugPrint('[PlayerWindowSession] Failed to defer session end: $e');
      unawaited(_endUnlessRejoined(generation));
    }
  }

  @override
  void onWindowLeaveFullScreen() {
    final signal = _fullscreenExitSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  bool _overtaken(int generation) =>
      generation != _generation || _members.isNotEmpty;

  Future<void> _endUnlessRejoined(int generation) async {
    if (_overtaken(generation)) return;

    var fullscreen = false;
    try {
      fullscreen = await _window.isFullScreen();
    } catch (e) {
      debugPrint('[PlayerWindowSession] Failed to check fullscreen: $e');
    }
    if (fullscreen) await _awaitFullscreenExit();
    if (_overtaken(generation)) return;

    final snapshot = _snapshot;
    final owner = _geometryOwner;
    _live = false;
    _snapshot = null;
    _geometryOwner = null;

    try {
      // Before setBounds: GTK applies geometry hints to programmatic
      // resizes too.
      await _window.setAspectRatio(0);
      // Maximizing or going fullscreen during playback is an explicit
      // choice. Restoring an old rect would fight it.
      final untouchable =
          await _window.isMaximized() || await _window.isFullScreen();
      // A join() can land during the awaits above -- a real platform
      // channel round trip is a genuine gap, not the fake's microtask. That
      // join already claimed the window with its own pause and snapshot;
      // applying this stale one now would clobber it.
      if (snapshot != null && !untouchable && _members.isEmpty) {
        await _window.setBounds(snapshot);
      }
    } catch (e) {
      debugPrint('[PlayerWindowSession] Failed to restore window: $e');
    } finally {
      // Always: leaving the controller paused would silently stop
      // persisting geometry for the rest of the app session. If a join()
      // landed above, its pause() already superseded this owner, so this
      // resume() is a documented no-op (see WindowGeometryController.resume)
      // rather than a real un-pause.
      _geometry.resume(owner);
    }
  }

  Future<void> _awaitFullscreenExit() async {
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
  }
}
