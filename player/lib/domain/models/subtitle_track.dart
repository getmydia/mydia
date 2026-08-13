import '../../graphql/fragments/media_file_fragment.graphql.dart';
import '../../graphql/mutations/download_subtitle.graphql.dart';

/// Represents a subtitle track available for a media file.
class SubtitleTrack {
  /// Unique identifier for the track
  final String id;

  /// ISO 639-2 language code (e.g., 'eng', 'spa')
  final String language;

  /// Human-readable title (optional)
  final String? title;

  /// URL for downloading/streaming the subtitle
  final String? url;

  /// Whether this is the default track
  final bool isDefault;

  /// Format of the subtitle (srt, vtt, ass)
  final String format;

  /// Whether the subtitle is embedded in the video file
  final bool embedded;

  /// Subtitle body already converted to WebVTT. Null for image-based tracks
  /// and for tracks the server could not read.
  ///
  /// Deliberately absent from `MediaFileFragment`: resolving `content` for
  /// an embedded track runs an ffmpeg extraction server-side, so it is
  /// populated lazily via the targeted `SubtitleContent` query rather than
  /// here in `fromGraphQL`.
  final String? content;

  /// False for image-based tracks (PGS, VobSub), which render only in direct
  /// play where the client reads them from the container itself.
  final bool deliverable;

  const SubtitleTrack({
    required this.id,
    required this.language,
    this.title,
    this.url,
    this.isDefault = false,
    this.format = 'srt',
    this.embedded = false,
    this.content,
    this.deliverable = true,
  });

  /// Create from GraphQL fragment
  factory SubtitleTrack.fromGraphQL(Fragment$MediaFileFragment$subtitles sub) {
    return SubtitleTrack(
      id: sub.trackId,
      language: sub.language,
      title: sub.title,
      url: sub.url,
      format: sub.format,
      embedded: sub.embedded,
      deliverable: sub.deliverable,
    );
  }

  /// Create from the track a `downloadSubtitle` mutation just wrote.
  ///
  /// [content] stays null on purpose. The mutation reports the new track's
  /// identity, not its body; the body is fetched once, lazily, by the
  /// `SubtitleContent` query when the viewer selects it -- the same path
  /// every other sidecar takes, rather than a second way in that only
  /// freshly downloaded tracks would use.
  factory SubtitleTrack.fromDownload(
    Mutation$DownloadSubtitle$downloadSubtitle track,
  ) {
    return SubtitleTrack(
      id: track.trackId,
      language: track.language,
      title: track.title,
      format: track.format,
      embedded: track.embedded,
      deliverable: track.deliverable,
    );
  }

  /// Returns a display name for the track
  String get displayName {
    if (title != null && title!.isNotEmpty) {
      return title!;
    }
    return _languageCodeToName(language);
  }

  /// Convert language code to human-readable name
  static String _languageCodeToName(String code) {
    const languageMap = {
      'eng': 'English',
      'spa': 'Spanish',
      'fre': 'French',
      'ger': 'German',
      'ita': 'Italian',
      'por': 'Portuguese',
      'rus': 'Russian',
      'jpn': 'Japanese',
      'kor': 'Korean',
      'chi': 'Chinese',
      'ara': 'Arabic',
      'hin': 'Hindi',
    };
    return languageMap[code] ?? code.toUpperCase();
  }

  /// Create from API response JSON
  factory SubtitleTrack.fromJson(Map<String, dynamic> json) {
    return SubtitleTrack(
      id: json['track_id'].toString(),
      language: json['language'] as String? ?? 'und',
      title: json['title'] as String?,
      format: json['format'] as String? ?? 'srt',
      embedded: json['embedded'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubtitleTrack &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
