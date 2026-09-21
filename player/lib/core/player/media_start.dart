import 'package:media_kit/media_kit.dart';

/// The [Media] to open so playback begins at [position], and whether the
/// caller must still seek there itself once `Player.open` returns.
///
/// On native the position travels inside the [Media] as mpv's `start`
/// option, which mpv applies while it loads the file. A seek sent after
/// `open` cannot be relied on: `open` returns once mpv has queued the file,
/// not once it has loaded it, mpv rejects a `seek` until playback is
/// initialized, and media_kit discards that rejection. Any source slower to
/// load than the caller's wait (a P2P fetch, a cold transcode) resumed at
/// zero, and the next progress sync then overwrote the saved position.
///
/// Web keeps the seek. media_kit ignores `start` when hls.js plays the
/// source, and otherwise clamps every reported position to it, which would
/// pin the position readout after a seek backwards.
({Media media, bool seekAfterOpen}) mediaStartingAt(
  String uri, {
  required Map<String, String> httpHeaders,
  required Duration position,
  required bool isWeb,
}) {
  final resumes = position > Duration.zero;
  return (
    media: Media(
      uri,
      httpHeaders: httpHeaders,
      start: resumes && !isWeb ? position : null,
    ),
    seekAfterOpen: resumes && isWeb,
  );
}
