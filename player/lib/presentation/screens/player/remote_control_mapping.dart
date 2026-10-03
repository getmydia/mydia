import '../../../native/lib.dart' show FlutterPlaybackState;

/// Converts the wire's 0.0-1.0 volume level to media_kit's 0-100 scale, used
/// by `_PlayerScreenState.setVolume`. Clamps out-of-range input rather than
/// trusting the caller: a remote peer, not this app, decides what crosses
/// the wire.
///
/// Extracted as a free function, alongside its inverse
/// [playerVolumeToRemoteControlVolume] and [remoteControlMuteVolume], so the
/// 0-1/0-100 conversion `_PlayerScreenState`'s `RemotePlayerBinding`
/// implementation depends on is directly unit-tested rather than only
/// exercised indirectly through `RemoteTargetController`'s own tests, which
/// drive a hand-written fake binding and never reach this arithmetic. See
/// `shouldRestartForSeek`'s dartdoc for why a real `Player` cannot stand in
/// for it under `flutter test` instead.
double remoteControlVolumeToPlayerVolume(double level) =>
    level.clamp(0.0, 1.0) * 100;

/// The inverse of [remoteControlVolumeToPlayerVolume], for reporting the
/// current volume back out through `_PlayerScreenState.describe`.
double playerVolumeToRemoteControlVolume(double playerVolume) =>
    playerVolume / 100;

/// media_kit has no separate mute flag on this screen, only volume: muting
/// snaps it to 0 and unmuting snaps it to full, mirroring
/// `_handleKeyEvent`'s existing `keyM` case exactly rather than restoring
/// whatever was set before muting, which would need new state this screen
/// does not keep.
double remoteControlMuteVolume(bool muted) => muted ? 0.0 : 100.0;

/// Whether `_PlayerScreenState.describe` should report the player as muted.
/// Paired with [remoteControlMuteVolume] rather than a tracked mute flag:
/// muted is exactly "volume is 0" (including when there is no player at
/// all, since `null == 0` is false).
bool isPlayerVolumeMuted(double? playerVolume) => playerVolume == 0;

/// Finds the element of [tracks] whose [idOf] equals [id], or null when
/// nothing matches: the case every `selectTrack` branch in
/// `_PlayerScreenState` must silently no-op for rather than throw, since
/// `id` names a track a *remote peer* chose, which this screen never
/// validated before it arrived.
T? findTrackById<T>(
  List<T> tracks,
  String id, {
  required String Function(T track) idOf,
}) =>
    tracks.where((track) => idOf(track) == id).firstOrNull;

/// Maps `_PlayerScreenState`'s own loading/error flags and the `Player`'s
/// state onto the wire's [FlutterPlaybackState], for
/// `_PlayerScreenState.describe` by way of
/// `_PlayerScreenState._remoteControlPlaybackState`.
///
/// Order is significant, checked in this priority: [hasError] wins over
/// everything else: a player still decoding through a stream error is not
/// meaningfully "playing". [isLoading]/`!hasPlayer` come next because this
/// screen's own `_isLoading`/`_error` fields describe *screen* phases where
/// `Player.state` may not exist yet or may be stale from a session this
/// screen already tore down, so they are trusted ahead of whatever the
/// `Player` itself reports. [buffering] and [completed] are checked before
/// [playing] because media_kit can report `playing: true` while buffering,
/// and after the file has already ended.
FlutterPlaybackState remoteControlPlaybackState({
  required bool hasError,
  required bool isLoading,
  required bool hasPlayer,
  required bool buffering,
  required bool completed,
  required bool playing,
}) {
  if (hasError) return FlutterPlaybackState.error;
  if (isLoading || !hasPlayer) return FlutterPlaybackState.loading;
  if (buffering) return FlutterPlaybackState.buffering;
  if (completed) return FlutterPlaybackState.ended;
  return playing ? FlutterPlaybackState.playing : FlutterPlaybackState.paused;
}

/// Casts to a remote target, stopping local playback only once the receiver
/// has confirmed the load, never before, and never at all if it refuses.
///
/// This ordering is what makes "Push" (spec term: capture position and
/// track selections, `Hello`, `LoadContent`, only then stop locally)
/// non-destructive. An unreachable receiver or a rejected codec must never
/// cost the viewer their place in a film: when [startCast] throws, [stopLocal]
/// simply never runs, and whatever `_PlayerScreenState._player` was doing
/// keeps doing it. The caller's own `catch` (see `_showCastDevicePicker`) is
/// what turns that exception into a toast instead of a crash.
///
/// Extracted as a free function for the same reason as `applyQualityChoice`
/// and `shouldRestartForSeek`: proving this ordering under `flutter test`
/// needs to observe whether local playback kept running, and this suite can
/// never construct a real, playing media_kit `Player` to observe that
/// against (see `shouldRestartForSeek`'s dartdoc), so the ordering itself
/// is what gets pinned instead, independent of any real player.
Future<void> pushToRemoteTarget({
  required Future<void> Function() startCast,
  required Future<void> Function() stopLocal,
}) async {
  await startCast();
  await stopLocal();
}
