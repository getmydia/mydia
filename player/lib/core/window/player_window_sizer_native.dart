import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'player_window_session.dart';
import 'player_window_sizer.dart';
import 'window_controller.dart';
import 'window_geometry_controller.dart';
import 'window_geometry_math.dart';

/// Two aspects closer than this are the same shape: an HLS rendition switch
/// re-emits the same shape at a new resolution.
const double _kAspectTolerance = 0.01;

/// Snaps the window to the video's aspect ratio while its player is mounted.
///
/// One per `PlayerScreen`. The browse snapshot and the geometry pause belong
/// to the shared [PlayerWindowSession], which is what carries the window
/// across next-episode navigation.
///
/// Nothing here is allowed to throw: it runs from `PlayerScreen.initState` and
/// `dispose`, where an exception would surface as a red screen mid-playback.
class NativePlayerWindowSizer with WindowListener implements PlayerWindowSizer {
  final WindowController _window;
  final PlayerWindowSession _session;
  final WorkAreaReader _readWorkAreas;

  /// Invoked once, on the first [detach]. The facade uses this to unregister
  /// the sizer from `windowManager`'s listener list; a sizer is built per
  /// player screen, so without it every screen would leak a listener.
  final void Function()? _onDetached;

  bool _attached = false;
  bool _detachNotified = false;

  StreamSubscription<VideoParams>? _paramsSubscription;

  /// The aspect currently applied, so a re-emitted or rendition-switched
  /// stream does not cause a second identical resize.
  double? _appliedAspect;

  /// The lock to hold while windowed: the applied aspect, or null when the
  /// minimum size forced a different shape (a lock would fight the floor)
  /// or nothing has been fitted yet.
  double? _lockedAspect;

  /// The window is maximized or fullscreen, per the latest window event.
  /// Updated unconditionally (even while detached) since it is just state;
  /// what reads it is gated on [_attached] itself.
  bool _filling = false;

  NativePlayerWindowSizer({
    required WindowController window,
    required PlayerWindowSession session,
    required WorkAreaReader readWorkAreas,
    void Function()? onDetached,
  })  : _window = window,
        _session = session,
        _readWorkAreas = readWorkAreas,
        _onDetached = onDetached;

  @override
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    _appliedAspect = null;
    _lockedAspect = null;
    _filling = false;
    await _session.join(this);
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

  /// Fits every new aspect from the window's *current* rect, so a manual
  /// resize (or the previous episode's window) is the starting point rather
  /// than something that switches fitting off.
  Future<void> _onVideoParams(VideoParams params) async {
    if (!_attached) return;

    final aspect = _aspectOf(params);
    if (aspect == null) return;

    final applied = _appliedAspect;
    if (applied != null && (applied - aspect).abs() < _kAspectTolerance) {
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

      // Several awaits deep: the screen may have gone, or a maximize/
      // fullscreen event may have landed and already dropped the (not yet
      // applied) lock -- applying one now, or resizing, would fight it.
      if (!_attached || _filling) return;

      final fitted = target.width / target.height;
      final lock = (fitted - aspect).abs() < _kAspectTolerance ? aspect : null;
      _appliedAspect = aspect;
      _lockedAspect = lock;
      // Before setBounds: GTK applies geometry hints to programmatic resizes
      // too, so the previous video's lock would bend the new rect. Its own
      // try, because a platform that cannot lock should still resize.
      await _applyLock(lock ?? 0);
      await _window.setBounds(target);
    } catch (e) {
      debugPrint('[PlayerWindowSizer] Failed to fit window to video: $e');
    }
  }

  // A maximized or fullscreen window must fill its space, which a lock
  // would prevent.
  @override
  void onWindowMaximize() {
    _filling = true;
    _dropLock();
  }

  @override
  void onWindowEnterFullScreen() {
    _filling = true;
    _dropLock();
  }

  @override
  void onWindowUnmaximize() {
    _filling = false;
    _reapplyLock();
  }

  @override
  void onWindowLeaveFullScreen() {
    _filling = false;
    _reapplyLock();
  }

  void _dropLock() {
    if (!_attached || _lockedAspect == null) return;
    unawaited(_applyLock(0));
  }

  void _reapplyLock() {
    final lock = _lockedAspect;
    if (!_attached || lock == null) return;
    unawaited(_applyLock(lock));
  }

  /// `setAspectRatio` is a GDK geometry hint on Linux, which Wayland
  /// compositors may ignore; the window then resizes freely, as before.
  Future<void> _applyLock(double aspect) async {
    try {
      await _window.setAspectRatio(aspect);
    } catch (e) {
      debugPrint('[PlayerWindowSizer] Failed to set aspect lock: $e');
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
    _appliedAspect = null;
    _lockedAspect = null;

    if (_attached) {
      _attached = false;
      _session.leave(this);
    }

    if (!_detachNotified) {
      _detachNotified = true;
      _onDetached?.call();
    }
  }
}
