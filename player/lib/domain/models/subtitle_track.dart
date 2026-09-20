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

  /// False for image-based tracks (PGS, VobSub, DVB, XSUB), which have no
  /// text body. Native players still show them: from the container in
  /// direct play, and as a bitmap sidecar when streaming. A server predating
  /// DVB and XSUB in its image list reports those as true, so read
  /// bitmap-ness from [format] (`isImageSubtitleFormat`), not from this.
  final bool deliverable;

  /// Whether this track subtitles only foreign dialogue and signs.
  ///
  /// False for an mpv-native track: media_kit reports a title and a language
  /// but no disposition, so the flag is unknown rather than absent. The
  /// preference matcher treats unknown as not-forced and leans on the title
  /// tiebreak for those.
  final bool forced;

  /// Whether this track carries sound descriptions for deaf and hard-of-hearing
  /// viewers. False for an mpv-native track, for the same reason as [forced].
  final bool hearingImpaired;

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
    this.forced = false,
    this.hearingImpaired = false,
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
      forced: sub.forced,
      hearingImpaired: sub.hearingImpaired,
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
      forced: track.forced,
      hearingImpaired: track.hearingImpaired,
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
