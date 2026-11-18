/// The macOS video surface: mpv's gpu-next output in a platform view, with
/// Flutter's subtitles and chrome over it.
///
/// `PlayerScreen` builds this instead of media_kit's `Video` when the
/// playback's [VideoOutputPath] is [VideoOutputPath.surface]. Every other
/// platform, and macOS on the texture path, keeps `Video`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../../core/player/mac_video_output.dart';
import '../../../core/player/mpv_surface_channel.dart';
import '../../../core/player/subtitle_size.dart';
import '../../../core/player/surface_attach_options.dart';
import '../../../core/player/video_scaling.dart';
import '../../../core/settings/settings_providers.dart';
import '../../../core/update/update_provider.dart';
import '../video_controls/chrome_subtitle_lift.dart';
import 'mydia_subtitle_view.dart';
import 'surface_subtitle_lift.dart';

/// How long the platform view may take to appear before the surface counts
/// as failed. Creating one is a single round trip to AppKit, so reaching
/// this means the plugin is missing, not slow.
const _viewCreationTimeout = Duration(seconds: 5);

/// How long a detach waits for the plugin's reply. The plugin itself gives
/// up on `current-vo` after 3 seconds; this also bounds the `vid=no` write
/// before that, and a serial queue held up by an mpv core that stopped
/// answering. On expiry the plugin keeps the host views alive, so the
/// player may still be disposed.
const _detachReplyTimeout = Duration(seconds: 5);

/// The surface's hold on one [Player]: its platform view, its handle while
/// attached, and the panscan it last sent.
///
/// One per player. The view is keyed globally so it survives the screen
/// moving it from the loading layout to the playing one: a new view would
/// be a new `NSView`, and the old one leaving its window detaches the
/// output.
class MpvSurfaceBinding {
  MpvSurfaceBinding({required this.player, required this.surface});

  final Player player;
  final MpvSurface surface;

  final viewKey = GlobalKey(debugLabel: 'mpv-surface');
  final subtitles = MydiaSubtitleViewController();

  final _viewId = Completer<int>();
  final _cancelled = Completer<void>();
  int? _handle;
  VideoScaling? _scaling;
  Future<void>? _detaching;

  void _onViewCreated(int id) {
    if (!_viewId.isCompleted) _viewId.complete(id);
  }

  /// Waits for the platform view and the player's handle, then attaches.
  /// False when the surface cannot be used: the view never appeared, the
  /// plugin refused, or [detach] ran first.
  Future<bool> attach() async {
    final int viewId;
    final int handle;
    try {
      final view =
          await _unlessCancelled(_viewId.future).timeout(_viewCreationTimeout);
      if (view == null) return false;
      viewId = view;
      final resolved = await _unlessCancelled(player.handle);
      if (resolved == null) return false;
      handle = resolved;
    } on TimeoutException {
      debugPrint('[MpvSurface] platform view never appeared');
      return false;
    }
    if (_cancelled.isCompleted) return false;
    // Before the call, so a detach racing this attach still detaches it:
    // the plugin runs both on one serial queue, in the order they arrive.
    _handle = handle;
    try {
      await surface.attach(handle, viewId);
    } on PlatformException catch (e) {
      debugPrint('[MpvSurface] attach failed: ${e.code} ${e.message}');
      return false;
    }
    // A detach sent while the attach was in flight is already queued behind
    // it: nothing more may go to a handle on its way out.
    if (_cancelled.isCompleted) return false;
    final scaling = _scaling;
    if (scaling != null) await _sendScaling(handle, scaling);
    return true;
  }

  /// [future]'s value, or null once [detach] has run.
  Future<T?> _unlessCancelled<T extends Object>(Future<T> future) =>
      Future.any<T?>([future, _cancelled.future.then((_) => null)]);

  /// How mpv's output came up. Call once the source's tracks are known.
  ///
  /// A check that could not run reads as [VideoOutputStart.timedOut]: it says
  /// nothing about whether gpu-next works on this Mac.
  Future<VideoOutputStart> awaitVideoOutput() async {
    final handle = _handle;
    if (handle == null) return VideoOutputStart.timedOut;
    try {
      return await surface.awaitVideoOutput(handle);
    } on PlatformException catch (e) {
      debugPrint('[MpvSurface] start check failed: ${e.code} ${e.message}');
      return VideoOutputStart.timedOut;
    }
  }

  /// Sends `panscan` for [scaling] now, or on attach.
  void applyScaling(VideoScaling scaling) {
    if (scaling == _scaling) return;
    _scaling = scaling;
    final handle = _handle;
    if (handle != null && !_cancelled.isCompleted) {
      unawaited(_sendScaling(handle, scaling));
    }
  }

  Future<void> _sendScaling(int handle, VideoScaling scaling) async {
    try {
      await surface.setOption(handle, 'panscan', panscanFor(scaling));
    } on PlatformException catch (e) {
      debugPrint('[MpvSurface] panscan failed: ${e.code} ${e.message}');
    }
  }

  /// Takes the output out of the view. Completes before the player may be
  /// disposed, within [_detachReplyTimeout], and never throws. Idempotent.
  Future<void> detach() => _detaching ??= _detach();

  Future<void> _detach() async {
    if (!_cancelled.isCompleted) _cancelled.complete();
    final handle = _handle;
    if (handle == null) return;
    try {
      await surface.detach(handle).timeout(_detachReplyTimeout);
    } on TimeoutException {
      debugPrint('[MpvSurface] detach got no reply within '
          '${_detachReplyTimeout.inSeconds}s; disposing anyway');
    } catch (e) {
      debugPrint('[MpvSurface] detach failed: $e');
    }
  }
}

/// The surface and what Flutter draws over it.
///
/// With [chrome] null (while loading) it is the bare view under [overlay].
class PlayerVideoSurface extends StatefulWidget {
  const PlayerVideoSurface({
    super.key,
    required this.binding,
    required this.scaling,
    required this.subtitleSize,
    this.chrome,
    this.overlay,
  });

  final MpvSurfaceBinding binding;
  final VideoScaling scaling;
  final SubtitleSize subtitleSize;
  final Widget Function(Player player, SubtitleLift lift)? chrome;
  final Widget? overlay;

  @override
  State<PlayerVideoSurface> createState() => _PlayerVideoSurfaceState();
}

class _PlayerVideoSurfaceState extends State<PlayerVideoSurface> {
  Size _box = Size.zero;

  @override
  void initState() {
    super.initState();
    widget.binding.applyScaling(widget.scaling);
  }

  @override
  void didUpdateWidget(PlayerVideoSurface old) {
    super.didUpdateWidget(old);
    widget.binding.applyScaling(widget.scaling);
  }

  @override
  Widget build(BuildContext context) {
    final binding = widget.binding;
    final player = binding.player;
    final chrome = widget.chrome;
    final overlay = widget.overlay;
    return LayoutBuilder(builder: (context, constraints) {
      _box = constraints.biggest;
      final subtitles = subtitleViewConfigurationFor(
          constraints.biggest, widget.subtitleSize);
      return Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: const Color(0xFF000000),
            child: AppKitView(
              key: binding.viewKey,
              viewType: mpvSurfaceViewType,
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: binding._onViewCreated,
            ),
          ),
          if (chrome != null) ...[
            // The same condition media_kit's `Video` puts on its
            // `SubtitleView`: with libass, mpv draws text subtitles itself.
            if (subtitles.visible &&
                !(player.platform?.configuration.libass ?? false))
              Positioned.fill(
                child: MydiaSubtitleView(
                  player: player,
                  configuration: subtitles,
                  controller: binding.subtitles,
                ),
              ),
            Positioned.fill(
              child: chrome(
                player,
                SurfaceSubtitleLift(
                  player: player,
                  subtitles: binding.subtitles,
                  box: () => _box,
                  scaling: () => widget.scaling,
                ),
              ),
            ),
          ],
          if (overlay != null) Positioned.fill(child: overlay),
        ],
      );
    });
  }
}

/// Decides the output for a playback that is about to start.
///
/// Reads from storage rather than through the hatch's provider, which is
/// auto-dispose and has no listener here. The decision itself is
/// [resolveVideoOutputChoice], shared with the device profile.
Future<MacVideoOutputChoice> resolveMacVideoOutput(WidgetRef ref) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) {
    return (path: VideoOutputPath.texture, failedEarlier: false);
  }
  final settings = ref.read(coreSettingsServiceProvider);
  final readVersion = ref.read(installedVersionReaderProvider);
  return resolveVideoOutputChoice(
    readLegacyHatch: settings.getLegacyMacVideoOutput,
    readFailedVersion: settings.getMacSurfaceFailedVersion,
    appVersion: await readInstalledVersion(readVersion),
  );
}

/// Records that the surface failed to start on the running app version, so
/// later playbacks take the texture path until an update.
///
/// Takes its reads before any await, so it is safe from a `State` that may
/// unmount meanwhile. The version is the one Diagnostics compares against.
Future<void> recordMacSurfaceFailure(WidgetRef ref) async {
  final settings = ref.read(coreSettingsServiceProvider);
  final readVersion = ref.read(installedVersionReaderProvider);
  final version = await readInstalledVersion(readVersion);
  if (version.isEmpty) return;
  try {
    await settings.setMacSurfaceFailedVersion(version);
  } catch (e) {
    debugPrint('[MpvSurface] Could not record the failure: $e');
  }
}
