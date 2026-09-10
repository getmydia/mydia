library;

/// How far past the transcoded window a seek may land before the HLS session
/// is torn down and restarted at the new position.
///
/// Restarting is expensive and visible: it ends the session, disposes the
/// player, makes two GraphQL round trips, starts a fresh FFmpeg and waits for
/// a playlist, all behind a spinner. Early in a session only a few seconds
/// have been transcoded — and that is exactly the state playback returns to
/// after every resume and every restart — so without a tolerance a single
/// 10-second arrow-key skip or double-tap-forward would overshoot the
/// seekable end and pay that cost, over and over, potentially looping.
///
/// Within this tolerance the seek is clamped to the seekable end instead,
/// which is what the player did before restarts existed. Only a deliberate
/// jump well beyond what has been transcoded is worth a restart.
const Duration kSeekRestartTolerance = Duration(seconds: 30);

/// Whether [_PlayerScreenState.seekToReal] must restart the HLS session
/// rather than seek the live player in place.
///
/// Extracted as a free function so the seek boundary math can be
/// unit-tested without a widget tree or a live `Player` — constructing a
/// real (non-fake-backed) `Player` requires native mpv/FFI
/// (`NativePlayer`'s constructor calls `DynamicLibrary.open` synchronously),
/// which is not available under `flutter test`; every other test in this
/// suite that needs a `Player` injects a fake `platformPlayer` for exactly
/// this reason, and `PlayerScreen` itself does not offer a way to do that.
/// Same pattern as [shouldOfferResume] and [handleEpisodeNavKey].
///
/// [seekableEnd] must be the player's own **raw**, unresolved
/// `player.state.duration` — see `seekToReal`'s own comment at its call site
/// for why that is deliberate rather than a bug: it is exactly how much of
/// the stream has been transcoded and can currently be seeked into, which a
/// [StreamTimeline]-resolved duration would not tell you.
///
/// Overshooting [seekableEnd] by up to [kSeekRestartTolerance] does not
/// restart: `seekToReal` clamps those to the seekable end instead. See that
/// constant for why a small skip on a cold stream must not cost a restart.
///
/// [fullPlaylist] short-circuits everything below it: once the server has
/// published a playlist covering the whole file, it relocates its own
/// encoder on demand, so every position is already addressable and no seek
/// ever needs a restart. The boundary math below only still exists for a
/// server too old to serve a full playlist, which is the sole remaining
/// reason a far seek must restart the session.
bool shouldRestartForSeek({
  required bool isDirectPlay,
  required bool fullPlaylist,
  required Duration realTarget,
  required Duration localTarget,
  required Duration seekableEnd,
  required Duration startOffset,
}) {
  // Direct play and offline playback hold the whole file locally — there is
  // no HLS session to restart, and the player's own duration is already the
  // true one, so seeking is always local for them.
  if (isDirectPlay) return false;

  // A full-length playlist covers the whole file and the server relocates its
  // encoder on demand, so every position is already addressable. This is the
  // path that makes a far scrub buffer rather than reload.
  if (fullPlaylist) return false;

  return localTarget > seekableEnd + kSeekRestartTolerance ||
      realTarget < startOffset;
}
