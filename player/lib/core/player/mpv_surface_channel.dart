/// The Dart side of `MpvSurfacePlugin` (`macos/Runner/MpvSurface/`).
library;

import 'package:flutter/services.dart';

import 'surface_attach_options.dart';

/// The platform view type the plugin registers.
const mpvSurfaceViewType = 'mydia/mpv-surface';

/// What the host window's screen offers, as the plugin reports it.
class DisplayInfo {
  const DisplayInfo({
    required this.edrHeadroom,
    required this.potentialHeadroom,
    required this.screenName,
  });

  /// How far above SDR white the screen can draw right now. 1 means no
  /// headroom.
  final double edrHeadroom;

  /// The most headroom the screen can ever offer.
  final double potentialHeadroom;
  final String screenName;

  static DisplayInfo fromMap(Map<Object?, Object?> map) => DisplayInfo(
        edrHeadroom: (map['edrHeadroom'] as num?)?.toDouble() ?? 1,
        potentialHeadroom: (map['potentialHeadroom'] as num?)?.toDouble() ?? 1,
        screenName: map['screenName'] as String? ?? '',
      );
}

/// What [MpvSurface.awaitVideoOutput] found.
enum VideoOutputStart {
  /// `current-vo` is set, or the source has no video.
  started,

  /// mpv rejected the video output: it deselected the video track (`vid`
  /// reads `no`, or no video entry in `track-list` is selected). This is
  /// what a gpu-next that cannot run on this Mac looks like.
  failed,

  /// Neither within 2 seconds: the output may only be slow to start.
  timedOut,
}

/// Puts an mpv player's video output into a platform view, and takes it out.
///
/// Every call reaches mpv on the plugin's own serial queue, never on the
/// main thread: mpv's mac output does `DispatchQueue.main.sync` while it is
/// created and destroyed.
abstract interface class MpvSurface {
  /// Writes `wid` (the view [viewId]), [surfaceAttachOptions], then
  /// `vid=auto`. Returns once the writes are done, before the output exists.
  /// Throws a [PlatformException] (`attach-failed`) when mpv refuses `wid`
  /// or `vid`; `wid` may already be set, so the caller still detaches.
  Future<void> attach(int handle, int viewId);

  /// How the output came up after `vid=auto`, checked for up to 2 seconds.
  /// [VideoOutputStart.started] at once for a source whose listed tracks
  /// include no video; [VideoOutputStart.timedOut] when mpv has listed no
  /// tracks by then.
  Future<VideoOutputStart> awaitVideoOutput(int handle);

  Future<void> setOption(int handle, String name, String value);

  /// Sets `vid=no` and waits, up to 3 seconds, for the output to go. Must
  /// complete before the player is disposed. When the output does not go,
  /// the plugin keeps the host view alive for good, so disposing the player
  /// afterwards is still safe.
  Future<void> detach(int handle);

  /// The host window's screen, on every change of screen or headroom.
  Stream<DisplayInfo> get display;
}

/// [MpvSurface] over the plugin's method and event channels.
class MpvSurfaceChannel implements MpvSurface {
  const MpvSurfaceChannel();

  static const _methods = MethodChannel('mydia/mpv-surface');
  static const _display = EventChannel('mydia/mpv-surface/display');

  @override
  Future<void> attach(int handle, int viewId) =>
      _methods.invokeMethod<void>('attach', {
        'handle': handle,
        'viewId': viewId,
        'options': [
          for (final (name, value) in surfaceAttachOptions()) [name, value],
        ],
      });

  @override
  Future<VideoOutputStart> awaitVideoOutput(int handle) async {
    final result = await _methods.invokeMapMethod<String, Object?>(
        'awaitVideoOutput', {'handle': handle});
    if (result?['started'] == true) return VideoOutputStart.started;
    if (result?['failed'] == true) return VideoOutputStart.failed;
    return VideoOutputStart.timedOut;
  }

  @override
  Future<void> setOption(int handle, String name, String value) =>
      _methods.invokeMethod<void>(
          'setOption', {'handle': handle, 'name': name, 'value': value});

  @override
  Future<void> detach(int handle) =>
      _methods.invokeMethod<void>('detach', {'handle': handle});

  @override
  Stream<DisplayInfo> get display => _display
      .receiveBroadcastStream()
      .map((event) => DisplayInfo.fromMap(event as Map<Object?, Object?>));
}
