import '../../core/player/streaming_strategy.dart';

/// A streaming candidate returned by the server's candidates endpoint.
///
/// Each candidate represents a potential streaming strategy with its
/// associated MIME type and codec information that the client can test
/// for compatibility.
class StreamingCandidate {
  /// The streaming strategy for this candidate
  final StreamingStrategy strategy;

  /// Full MIME type string with codec info (e.g., 'video/mp4; codecs="avc1.640028, mp4a.40.2"')
  final String mime;

  /// Container format (e.g., 'mp4', 'ts', 'webm')
  final String container;

  /// Video codec string in RFC 6381 format (e.g., 'avc1.640028')
  final String videoCodec;

  /// Audio codec string in RFC 6381 format (e.g., 'mp4a.40.2')
  final String? audioCodec;

  const StreamingCandidate({
    required this.strategy,
    required this.mime,
    required this.container,
    required this.videoCodec,
    this.audioCodec,
  });

  factory StreamingCandidate.fromJson(Map<String, dynamic> json) {
    final strategyValue = json['strategy'] as String;
    final strategy = StreamingStrategy.fromValue(strategyValue);

    if (strategy == null) {
      throw FormatException('Unknown streaming strategy: $strategyValue');
    }

    return StreamingCandidate(
      strategy: strategy,
      mime: json['mime'] as String,
      container: json['container'] as String,
      videoCodec: json['video_codec'] as String,
      audioCodec: json['audio_codec'] as String?,
    );
  }

  @override
  String toString() => 'StreamingCandidate(strategy: $strategy, mime: $mime)';
}

/// Metadata about the source media file
class StreamingMetadata {
  /// Duration in seconds
  final double? duration;

  /// Video width in pixels
  final int? width;

  /// Video height in pixels
  final int? height;

  /// Bitrate in bits per second
  final int? bitrate;

  /// Human-readable resolution (e.g., '1080p', '4K')
  final String? resolution;

  /// HDR format if applicable (e.g., 'HDR10', 'Dolby Vision')
  final String? hdrFormat;

  /// Original video codec name (e.g., 'h264', 'hevc')
  final String? originalCodec;

  /// Original audio codec name (e.g., 'aac', 'ac3')
  final String? originalAudioCodec;

  /// Original container format (e.g., 'mkv', 'mp4')
  final String? container;

  const StreamingMetadata({
    this.duration,
    this.width,
    this.height,
    this.bitrate,
    this.resolution,
    this.hdrFormat,
    this.originalCodec,
    this.originalAudioCodec,
    this.container,
  });

  factory StreamingMetadata.fromJson(Map<String, dynamic> json) {
    return StreamingMetadata(
      duration: (json['duration'] as num?)?.toDouble(),
      width: json['width'] as int?,
      height: json['height'] as int?,
      bitrate: json['bitrate'] as int?,
      resolution: json['resolution'] as String?,
      hdrFormat: json['hdr_format'] as String?,
      originalCodec: json['original_codec'] as String?,
      originalAudioCodec: json['original_audio_codec'] as String?,
      container: json['container'] as String?,
    );
  }
}

/// Response from the streaming candidates endpoint
class StreamingCandidatesResponse {
  /// List of streaming candidates in priority order (best first)
  final List<StreamingCandidate> candidates;

  /// Metadata about the source media
  final StreamingMetadata metadata;

  const StreamingCandidatesResponse({
    required this.candidates,
    required this.metadata,
  });

  factory StreamingCandidatesResponse.fromJson(Map<String, dynamic> json) {
    final candidatesList = (json['candidates'] as List<dynamic>)
        .map((c) => StreamingCandidate.fromJson(c as Map<String, dynamic>))
        .toList();

    final metadata = StreamingMetadata.fromJson(
      json['metadata'] as Map<String, dynamic>,
    );

    return StreamingCandidatesResponse(
      candidates: candidatesList,
      metadata: metadata,
    );
  }
}
