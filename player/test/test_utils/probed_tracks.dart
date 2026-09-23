import 'package:media_kit/media_kit.dart';

/// What mpv reports once it has actually probed a file: the `auto`/`no`
/// pseudo-tracks every media_kit `Tracks` carries before that, plus one real
/// video track and one real audio track.
///
/// `awaitRealTracks` (`lib/core/player/tracks_ready.dart`) only looks at
/// video/audio, so a fake `PlatformPlayer` whose `open` reports only a
/// subtitle track never reads as probed, and every test using it burns the
/// full timeout waiting for a real track that never arrives.
///
/// [subtitle] defaults to the same `auto`/`no` pseudo-tracks `Tracks()`
/// itself defaults to; pass a fake's own mpv subtitle track(s) to combine
/// them with the probed video/audio tracks below.
Tracks probedTracks({
  List<SubtitleTrack> subtitle = const [
    SubtitleTrack('auto', null, null),
    SubtitleTrack('no', null, null),
  ],
}) =>
    Tracks(
      video: const [
        VideoTrack('auto', null, null),
        VideoTrack('no', null, null),
        VideoTrack('1', null, null),
      ],
      audio: const [
        AudioTrack('auto', null, null),
        AudioTrack('no', null, null),
        AudioTrack('1', null, 'eng'),
      ],
      subtitle: subtitle,
    );
