import 'package:media_kit/media_kit.dart';

import 'subtitle_stream_index_stub.dart'
    if (dart.library.io) 'subtitle_stream_index_native.dart' as platform;

/// mpv's ffmpeg stream index for each subtitle track read from the loaded
/// file, keyed by mpv track id (the `id` media_kit reports on a
/// `SubtitleTrack`).
///
/// The server numbers embedded subtitle tracks by the same ffprobe stream
/// index, so this is what lets a track picked in direct play be found again
/// in a transcode, and the other way round. mpv documents `ff-index` as
/// exact for libavformat and usually right for its own mkv demuxer, which
/// is why callers also compare languages before trusting a match.
///
/// Empty on web, where there is no mpv, and on any failed read. A missing
/// index means "cannot match", never an error.
Future<Map<String, int>> subtitleStreamIndices(Player player) =>
    platform.subtitleStreamIndices(player);

/// A media_kit platform that is not mpv but can say which mpv subtitle track
/// is selected, as [selectedMpvSubtitleId] reads it. The seam a widget test's
/// player implements to stand in for mpv's `sid`.
abstract interface class SelectedMpvSubtitle {
  /// mpv's id for the selected subtitle track, or null for none.
  String? get selectedSubtitleId;
}

/// mpv's id for the subtitle track selected right now (its `sid`), in the
/// form media_kit reports on a `SubtitleTrack`. Read straight after a
/// `sub-add ... select`, it is the id mpv gave the file just added.
///
/// Null on web, where there is no mpv, when nothing is selected, and on any
/// failed read.
Future<String?> selectedMpvSubtitleId(Player player) async {
  final source = player.platform;
  if (source is SelectedMpvSubtitle) {
    return (source as SelectedMpvSubtitle).selectedSubtitleId;
  }
  return platform.selectedMpvSubtitleId(player);
}
