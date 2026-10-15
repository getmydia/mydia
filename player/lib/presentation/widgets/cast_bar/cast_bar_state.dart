import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cast/cast_providers.dart';
import '../../../core/cast/cast_session_manager.dart';
import '../../../core/cast/cast_target.dart';
import '../../../core/p2p/p2p_service.dart' show p2pStatusNotifierProvider;
import '../../../core/playback/local_playback_state.dart';
import '../../../core/remote/ambient_dismissals.dart';
import '../../../core/remote/ambient_targets.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/models/cast_device.dart';

/// What the cast bar shows, whichever surface draws it: the Flutter
/// `CastMiniController` or the native tab bar's accessory.
sealed class CastBarState {
  const CastBarState();
}

/// "Playing on X": a paired player mid-watch that nobody asked this device
/// to track.
final class CastBarAmbient extends CastBarState {
  const CastBarAmbient({required this.target, required this.deviceName});
  final AmbientTarget target;

  /// Already resolved against the paired-device roster.
  final String deviceName;
}

/// A device is remembered but nothing is connected.
final class CastBarOffline extends CastBarState {
  const CastBarOffline(this.device);
  final CastDevice device;
}

final class CastBarConnecting extends CastBarState {
  const CastBarConnecting(this.device);
  final CastDevice device;
}

/// The receiver dropped off with media to re-cast.
final class CastBarStale extends CastBarState {
  const CastBarStale(this.session);
  final CastSession session;
}

/// Connected, nothing loaded.
final class CastBarIdle extends CastBarState {
  const CastBarIdle(this.device);
  final CastDevice device;
}

/// Connected with media. `session.mediaInfo` is never null here.
final class CastBarPlaying extends CastBarState {
  const CastBarPlaying(this.session);
  final CastSession session;
}

/// What the cast bar should show, or null for nothing.
///
/// Auto-dispose, like [ambientPlayingProvider] underneath it: the ambient
/// probe holds live connections, and only runs while something is showing
/// the bar.
final castBarStateProvider = Provider.autoDispose<CastBarState?>((ref) {
  final capabilities = ref.watch(castCapabilitiesProvider);
  // `capabilities` describes only Chromecast/DLNA platform entitlement.
  // A Mydia target needs none of that — it is reached over the
  // already-connected p2p host, not the platform's local-network
  // discovery — so `castDiscoveryProvider` and `cast_device_picker.dart`
  // both already keep it ungated for the same reason (see
  // `castDiscoveryProvider`'s own dartdoc in `cast_providers.dart`).
  // Gating the whole bar on `capabilities.any` alone means this never
  // mounts on a build with no other capability at all — Flutter Web,
  // `ambient_lifecycle.dart` names as this app's primary deployment —
  // which would make both the ambient "Playing on X" banner and the
  // pull-to-local button unreachable there.
  final hasMydia = ref.watch(mydiaCastBackendProvider) != null;
  if (!capabilities.any && !hasMydia) return null;

  // Gate on a Mydia server before touching anything else in the cast stack.
  // Building the cast chain before a server is stored does work for
  // nothing: you cannot be casting before you have a server, so there is
  // nothing to show.
  if (!ref.watch(hasMydiaProvider)) return null;

  final session = ref.watch(castSessionProvider).value;
  final target = ref.watch(castTargetProvider);
  final isLocalPlaying = ref.watch(localPlaybackActiveProvider);

  if (session == null) {
    if (isLocalPlaying) return null;
    // A remembered device with no session at all: a connect that failed.
    // With neither, there is nothing of this device's own to show — which
    // is exactly when an ambient banner about a *different* paired player
    // belongs: an active cast (of this device's own) already claims the
    // bar, and stacking a third party's "Playing on X" underneath it
    // would just be noise.
    return target == null ? _ambient(ref) : CastBarOffline(target);
  }
  if (session.connectionState == CastConnectionState.connecting) {
    return CastBarConnecting(session.device);
  }
  if (session.isStale) {
    // The media reconnect re-casts what was playing. With no media there is
    // nothing to re-cast, so a media-less drop gets a plain reconnect.
    return session.mediaInfo == null
        ? CastBarOffline(session.device)
        : CastBarStale(session);
  }
  if (session.mediaInfo == null) return CastBarIdle(session.device);
  return CastBarPlaying(session);
});

/// "Playing on Living Room" for a paired player already mid-watch that
/// nobody asked this device to track — from [ambientPlayingProvider]
/// (`AmbientTargets`, `core/remote/ambient_targets.dart`). Null when there
/// is nothing ambient to show, which is the ordinary case: most of the
/// time no other paired device is playing anything at all.
///
/// Only ever one row, the first target held: a user with more than one
/// other device mid-watch at once is a corner the picker already covers,
/// and this banner's whole point is a glanceable nudge, not a second
/// picker. Shows the first held target that is neither this device nor
/// dismissed.
CastBarAmbient? _ambient(Ref ref) {
  final held = ref.watch(ambientPlayingProvider).value ?? const [];
  final dismissed = ref.watch(ambientDismissalsProvider);
  final selfNodeId =
      ref.watch(p2pStatusNotifierProvider.select((s) => s.nodeId));

  final ambientTarget = held
      .where((t) =>
          selfNodeId == null ||
          t.device.id.toLowerCase() != selfNodeId.toLowerCase())
      .where((t) => !dismissed.contains(AmbientDismissal.of(t)))
      .firstOrNull;
  if (ambientTarget == null) return null;

  // `AmbientTarget.device.name` is the bare node id — the probe this came
  // from carries no display names (see that field's own dartdoc) — so
  // resolve the real one against the paired-device roster before it ever
  // reaches the label. Falls back to the id itself only in the narrow
  // window before `remoteDeviceNamesProvider` has resolved.
  final names = ref.watch(remoteDeviceNamesProvider).value ?? const {};
  return CastBarAmbient(
    target: ambientTarget,
    deviceName: names[ambientTarget.device.id] ?? ambientTarget.device.id,
  );
}

/// The words the cast bar uses, shared with the native accessory so the two
/// cannot drift.
abstract final class CastBarText {
  /// "Ready to play on" rather than "Will play on": this is a statement about
  /// a connection that exists, not a promise about the future.
  static String idleTitle(String device) => 'Ready to play on $device';
  static const String idleStatus = 'Connected';
  static String connectingTitle(String device) => 'Connecting to $device…';
  static const String offlineStatus = 'Not connected';
  static String staleStatus(String device) => 'Lost connection to $device';
  static String ambientStatus(String device) => 'Playing on $device';
  static String playingStatus(String device, {required bool syncing}) =>
      syncing ? 'Reconnecting to $device…' : 'Casting to $device';
}

/// The play/pause control, shared by the bar's button and the native
/// accessory. Does nothing while [session] is syncing: the play state on
/// screen may be minutes old, so a toggle could go the wrong way.
Future<void> toggleCastPlayback(
  CastSessionManager manager,
  CastSession session,
) {
  if (session.isSyncing) return Future.value();
  return session.playbackState == CastPlaybackState.playing
      ? manager.pause()
      : manager.play();
}
