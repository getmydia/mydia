import '../../graphql/fragments/media_info_fragment.graphql.dart';
import 'subtitle_track.dart';

/// What kind of elementary stream this is.
enum MediaStreamType { video, audio, subtitle }

/// One elementary stream of a media file, as reported by ffprobe.
///
/// Values are raw; `stream_formatters.dart` turns them into display strings.
class MediaStream {
  final int? index;
  final MediaStreamType type;
  final String? codec;
  final String? codecLong;
  final String? profile;
  final int? level;
  final String? language;
  final String? title;
  final int? bitrate;

  final bool isDefault;
  final bool isForced;
  final bool isHearingImpaired;
  final bool isCommentary;

  final int? width;
  final int? height;
  final double? frameRate;
  final String? pixelFormat;
  final int? bitDepth;
  final String? colorSpace;
  final String? colorTransfer;
  final String? colorPrimaries;
  final int? dolbyVisionProfile;
  final String? aspectRatio;

  final int? channels;
  final String? channelLayout;
  final int? sampleRate;

  const MediaStream({
    this.index,
    required this.type,
    this.codec,
    this.codecLong,
    this.profile,
    this.level,
    this.language,
    this.title,
    this.bitrate,
    this.isDefault = false,
    this.isForced = false,
    this.isHearingImpaired = false,
    this.isCommentary = false,
    this.width,
    this.height,
    this.frameRate,
    this.pixelFormat,
    this.bitDepth,
    this.colorSpace,
    this.colorTransfer,
    this.colorPrimaries,
    this.dolbyVisionProfile,
    this.aspectRatio,
    this.channels,
    this.channelLayout,
    this.sampleRate,
  });

  factory MediaStream.fromGraphQL(Fragment$MediaInfoFragment$streams s) {
    return MediaStream(
      index: s.index,
      type: _typeFrom(s.type),
      codec: s.codec,
      codecLong: s.codecLong,
      profile: s.profile,
      level: s.level,
      language: s.language,
      title: s.title,
      bitrate: s.bitrate,
      isDefault: s.isDefault ?? false,
      isForced: s.isForced ?? false,
      isHearingImpaired: s.isHearingImpaired ?? false,
      isCommentary: s.isCommentary ?? false,
      width: s.width,
      height: s.height,
      frameRate: s.frameRate,
      pixelFormat: s.pixelFormat,
      bitDepth: s.bitDepth,
      colorSpace: s.colorSpace,
      colorTransfer: s.colorTransfer,
      colorPrimaries: s.colorPrimaries,
      dolbyVisionProfile: s.dolbyVisionProfile,
      aspectRatio: s.aspectRatio,
      channels: s.channels,
      channelLayout: s.channelLayout,
      sampleRate: s.sampleRate,
    );
  }

  static MediaStreamType _typeFrom(dynamic value) {
    final name = value.toString().split('.').last.toLowerCase();
    switch (name) {
      case 'audio':
        return MediaStreamType.audio;
      case 'subtitle':
        return MediaStreamType.subtitle;
      default:
        return MediaStreamType.video;
    }
  }
}

/// One media file, with everything the Media Info panel shows about it.
class MediaFileInfo {
  final String id;
  final String? fileName;
  final String? directory;
  final String? container;
  final double? durationSeconds;
  final int? sizeBytes;
  final int? bitrate;
  final String? resolution;
  final String? codec;

  /// Null when the server has not captured detailed streams for this file yet,
  /// which is the normal state until the backfill reaches it. Distinct from an
  /// empty list, which means capture ran and found nothing.
  final List<MediaStream>? streams;

  final List<SubtitleTrack> externalSubtitles;

  const MediaFileInfo({
    required this.id,
    this.fileName,
    this.directory,
    this.container,
    this.durationSeconds,
    this.sizeBytes,
    this.bitrate,
    this.resolution,
    this.codec,
    this.streams,
    this.externalSubtitles = const [],
  });

  bool get hasDetailedStreams => streams != null && streams!.isNotEmpty;

  List<MediaStream> ofType(MediaStreamType type) =>
      (streams ?? const []).where((s) => s.type == type).toList();

  /// Short label for the version switcher, e.g. "2160p HEVC · 54.2 GB".
  String get versionLabel {
    final parts = <String>[
      if (resolution != null) resolution!,
      if (codec != null) codec!.toUpperCase(),
    ];
    return parts.isEmpty ? 'Version' : parts.join(' ');
  }

  factory MediaFileInfo.fromGraphQL(Fragment$MediaInfoFragment f) {
    return MediaFileInfo(
      id: f.id,
      fileName: f.fileName,
      directory: f.directory,
      container: f.container,
      durationSeconds: f.duration,
      sizeBytes: f.size,
      bitrate: f.bitrate,
      resolution: f.resolution,
      codec: f.codec,
      streams: f.streams
          ?.whereType<Fragment$MediaInfoFragment$streams>()
          .map(MediaStream.fromGraphQL)
          .toList(),
      externalSubtitles: (f.externalSubtitles ?? [])
          .whereType<Fragment$MediaInfoFragment$externalSubtitles>()
          .map((s) => SubtitleTrack(
                id: s.trackId,
                language: s.language,
                title: s.title,
                format: s.format,
                embedded: s.embedded,
              ))
          .toList(),
    );
  }
}
