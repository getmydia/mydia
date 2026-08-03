import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'player_window_sizer.dart';
import 'window_controller.dart';
import 'window_geometry_controller.dart';
import 'window_geometry_math.dart';

/// Snaps the window to the video's aspect ratio while the player is mounted.
///
/// Nothing here is allowed to throw: it runs from `PlayerScreen.initState` and
/// `dispose`, where an exception would surface as a red screen mid-playback.
class NativePlayerWindowSizer implements PlayerWindowSizer {
  final WindowController _window;
  final WindowGeometryController _geometry;
  final WorkAreaReader _readWorkAreas;

  /// The window as it was before the player took over. Restored on detach.
  Rect? _snapshot;
  bool _attached = false;

  StreamSubscription<VideoParams>? _paramsSubscription;

  /// The aspect currently applied, so a re-emitted or rendition-switched
  /// stream does not cause a second identical resize.
  double? _appliedAspect;

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
    unawaited(_paramsSubscription?.cancel());
    _paramsSubscription = params.listen(
      (p) => unawaited(_onVideoParams(p)),
      onError: (Object e) =>
          debugPrint('[PlayerWindowSizer] Video params stream error: $e'),
    );
  }

  Future<void> _onVideoParams(VideoParams params) async {
    if (!_attached) return;

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

      _appliedAspect = aspect;
      await _window.setBounds(target);
    } catch (e) {
      debugPrint('[PlayerWindowSizer] Failed to fit window to video: $e');
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
