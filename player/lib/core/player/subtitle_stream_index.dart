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
