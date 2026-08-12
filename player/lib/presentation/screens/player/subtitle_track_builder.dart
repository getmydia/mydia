import '../../../domain/models/subtitle_track.dart';

/// Which subtitle tracks the user may pick from, given the delivery mode.
///
/// Image-based tracks (PGS, VobSub) are bitmaps. In direct play the media
/// engine reads them straight from the container and renders them natively,
/// so they stay selectable. When streaming, the server can only hand back
/// text, so only [SubtitleTrack.deliverable] tracks are offered.
///
/// This filter runs before any subtitle body has been fetched: [content] is
/// resolved lazily, once, when the viewer actually selects a track (see
/// `_resolveMediaKitSubtitleTrack` in `player_screen.dart`), never here. A
/// filter that inspected `content` at this stage would drop every
/// streaming-eligible track before the viewer got a chance to pick one.
List<SubtitleTrack> selectableTracks(
  List<SubtitleTrack> tracks, {
  required bool isDirectPlay,
}) {
  if (isDirectPlay) return tracks;

  return tracks.where((t) => t.deliverable).toList();
}
