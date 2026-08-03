import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'player_window_sizer.dart';
import 'window_controller.dart';
import 'window_geometry_controller.dart';

/// Snaps the window to the video's aspect ratio while the player is mounted.
///
/// Nothing here is allowed to throw: it runs from `PlayerScreen.initState` and
/// `dispose`, where an exception would surface as a red screen mid-playback.
class NativePlayerWindowSizer implements PlayerWindowSizer {
  final WindowController _window;
  final WindowGeometryController _geometry;
  // ignore: unused_field
  final WorkAreaReader _readWorkAreas; // Used by the aspect-snap in Task 9.

  /// The window as it was before the player took over. Restored on detach.
  Rect? _snapshot;
  bool _attached = false;

  StreamSubscription<VideoParams>? _paramsSubscription;

  NativePlayerWindowSizer({
    required WindowController window,
    required WindowGeometryController geometry,
    required WorkAreaReader readWorkAreas,
  })  : _window = window,
        _geometry = geometry,
        _readWorkAreas = readWorkAreas;

  @override
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    // Pause first: a resize event already queued by the user must not land
    // after we start reshaping the window.
    _geometry.pause();

    try {
      _snapshot = await _window.getBounds();
    } catch (e) {
      debugPrint('[PlayerWindowSizer] Failed to snapshot window bounds: $e');
    }
  }

  @override
  void bindVideoParams(Stream<VideoParams> params) {
    // Filled in by the next task.
  }

  @override
  Future<void> detach() async {
    unawaited(_paramsSubscription?.cancel());
    _paramsSubscription = null;

    final snapshot = _snapshot;
    _snapshot = null;
    _attached = false;

    try {
      // Maximizing or going fullscreen during playback is an explicit choice.
      // Restoring an old rect would fight it.
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
      _geometry.resume();
    }
  }
}
