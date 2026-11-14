/// What the Media Info panel shows for one indexed file: the index's details,
/// overridden by an on-device probe when there is one.
library;

import '../../../../domain/models/media_stream.dart';
import '../../../../domain/models/subtitle_track.dart';
import '../../../player/mpv_probe_mapping.dart' show ProbeResult;
import '../files_queries.dart';
import '../index/index_records.dart' show IndexedFile, LibraryRoot;

/// [file] under [root] as a [MediaFileInfo]. Without [probe], `streams` is
/// null and resolution, codec, duration and bitrate are unknown.
MediaFileInfo filesMediaFileInfo({
  required IndexedFile file,
  required LibraryRoot root,
  ProbeResult? probe,
}) {
  final full = filesBackendPath(root, file.path);
  final slash = full.lastIndexOf(RegExp(r'[/\\]'));
  final fileName = slash < 0 ? full : full.substring(slash + 1);
  final directory = slash < 0 ? null : full.substring(0, slash);
  final dot = fileName.lastIndexOf('.');
  final extension = dot <= 0 ? null : fileName.substring(dot + 1).toLowerCase();

  final duration = probe?.durationSeconds;
  // The mapping owns size * 8 / duration using mpv's file-size. This covers
  // only a probe that reported no file-size, using the index's size.
  final bitrate = probe == null
      ? null
      : probe.bitrate ??
          (duration != null && duration > 0 && file.size > 0
              ? (file.size * 8 / duration).round()
              : null);

  return MediaFileInfo(
    id: file.key,
    fileName: fileName,
    directory: directory,
    container: probe?.container ?? extension,
    durationSeconds: duration,
    sizeBytes: file.size,
    bitrate: bitrate,
    resolution: probe?.resolution,
    codec: probe?.videoCodec,
    streams: probe?.streams,
    externalSubtitles: [
      for (final s in FilesCatalog.sidecarStreams(root, file))
        SubtitleTrack(
          id: s.id,
          language: s.language ?? 'und',
          title: s.title,
          format: s.codec ?? '',
          embedded: false,
        ),
    ],
  );
}
