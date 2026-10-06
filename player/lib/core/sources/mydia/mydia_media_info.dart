/// Mydia `MediaInfoFragment` payloads to [MediaFileInfo].
library;

import '../../../domain/models/media_stream.dart';
import '../../../domain/models/subtitle_track.dart';

/// Maps one `MediaInfoFragment` payload onto [MediaFileInfo].
MediaFileInfo mediaFileInfoFromJson(Map<String, dynamic> json) {
  final streams = json['streams'] as List<dynamic>?;
  final external = json['externalSubtitles'] as List<dynamic>?;

  return MediaFileInfo(
    id: json['id'].toString(),
    fileName: json['fileName'] as String?,
    directory: json['directory'] as String?,
    container: json['container'] as String?,
    durationSeconds: (json['duration'] as num?)?.toDouble(),
    sizeBytes: json['size'] as int?,
    bitrate: json['bitrate'] as int?,
    resolution: json['resolution'] as String?,
    codec: json['codec'] as String?,
    streams:
        streams?.cast<Map<String, dynamic>>().map(_streamFromJson).toList(),
    externalSubtitles: (external ?? const [])
        .cast<Map<String, dynamic>>()
        .map(_externalSubtitleFromJson)
        .toList(growable: false),
  );
}

SubtitleTrack _externalSubtitleFromJson(Map<String, dynamic> json) {
  return SubtitleTrack(
    id: json['trackId'].toString(),
    language: json['language'] as String? ?? 'und',
    title: json['title'] as String?,
    format: json['format'] as String? ?? 'srt',
    embedded: json['embedded'] as bool? ?? false,
  );
}

MediaStream _streamFromJson(Map<String, dynamic> json) {
  return MediaStream(
    index: json['index'] as int?,
    type: _typeFromName(json['type'] as String?),
    codec: json['codec'] as String?,
    codecLong: json['codecLong'] as String?,
    profile: json['profile'] as String?,
    level: json['level'] as int?,
    language: json['language'] as String?,
    title: json['title'] as String?,
    bitrate: json['bitrate'] as int?,
    isDefault: json['isDefault'] as bool? ?? false,
    isForced: json['isForced'] as bool? ?? false,
    isHearingImpaired: json['isHearingImpaired'] as bool? ?? false,
    isCommentary: json['isCommentary'] as bool? ?? false,
    width: json['width'] as int?,
    height: json['height'] as int?,
    frameRate: (json['frameRate'] as num?)?.toDouble(),
    pixelFormat: json['pixelFormat'] as String?,
    bitDepth: json['bitDepth'] as int?,
    colorSpace: json['colorSpace'] as String?,
    colorTransfer: json['colorTransfer'] as String?,
    colorPrimaries: json['colorPrimaries'] as String?,
    dolbyVisionProfile: json['dolbyVisionProfile'] as int?,
    aspectRatio: json['aspectRatio'] as String?,
    channels: json['channels'] as int?,
    channelLayout: json['channelLayout'] as String?,
    sampleRate: json['sampleRate'] as int?,
  );
}

MediaStreamType _typeFromName(String? name) {
  switch (name?.toUpperCase()) {
    case 'AUDIO':
      return MediaStreamType.audio;
    case 'SUBTITLE':
      return MediaStreamType.subtitle;
    default:
      return MediaStreamType.video;
  }
}
