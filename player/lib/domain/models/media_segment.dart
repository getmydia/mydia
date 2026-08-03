/// A region of a media file the viewer may want to skip.
enum SegmentType { intro, credits, unknown }

/// A detected skippable segment, as delivered by the server.
///
/// The server applies its own confidence threshold before sending these, so
/// anything that arrives here is considered trustworthy enough to act on. The
/// player deliberately holds no threshold logic of its own.
class MediaSegment {
  const MediaSegment({
    required this.type,
    required this.startMs,
    required this.endMs,
  });

  /// Builds a segment from a decoded GraphQL map.
  ///
  /// Every field is read defensively. Mydia is self-hosted with no coordinated
  /// deploy order, so a newer player regularly meets an older server whose
  /// schema carries no segment fields at all. A missing or malformed value has
  /// to mean "no skip affordance", never a playback error.
  factory MediaSegment.fromJson(Map<String, dynamic> json) {
    return MediaSegment(
      type: _parseType(json['type']),
      startMs: (json['startMs'] as num?)?.toInt() ?? 0,
      endMs: (json['endMs'] as num?)?.toInt() ?? 0,
    );
  }

  /// Parses a `segments` collection out of a decoded GraphQL payload.
  ///
  /// Anything that is not a well-formed list of maps yields an empty list, so
  /// an older server that answered the whole query with a field error lands on
  /// the same result as a season nothing was detected in.
  static List<MediaSegment> listFromJson(dynamic raw) {
    final segments = <MediaSegment>[];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map<String, dynamic>) {
          segments.add(MediaSegment.fromJson(entry));
        }
      }
    }
    return segments;
  }

  /// Picks the segments for [fileId] out of a decoded segments-query payload.
  ///
  /// [root] is the query's root field, `movie` or `episode`.
  ///
  /// Reads the raw response map rather than a generated result class for two
  /// reasons: the movie and episode queries generate distinct types for an
  /// identical selection, so one code path here serves both; and a shape
  /// surprise from an unfamiliar server yields an empty list rather than a
  /// cast error, which is the whole point of this path being additive.
  static List<MediaSegment> forFile(
    Map<String, dynamic>? data, {
    required String root,
    required String fileId,
  }) {
    if (data == null) return const [];

    final media = data[root];
    if (media is! Map) return const [];

    final files = media['files'];
    if (files is! List) return const [];

    for (final file in files) {
      if (file is! Map) continue;
      if (file['id'] != fileId) continue;
      return listFromJson(file['segments'])
          .where((segment) => segment.actionable)
          .toList(growable: false);
    }

    return const [];
  }

  final SegmentType type;
  final int startMs;
  final int endMs;

  static SegmentType _parseType(dynamic raw) {
    switch (raw) {
      case 'INTRO':
      case 'intro':
        return SegmentType.intro;
      case 'CREDITS':
      case 'credits':
        return SegmentType.credits;
      default:
        return SegmentType.unknown;
    }
  }

  /// Whether [position] falls inside this segment.
  ///
  /// Inclusive of the start, exclusive of the end, so the button disappears at
  /// the instant a skip would have landed.
  bool containsPosition(Duration position) {
    final ms = position.inMilliseconds;
    return ms >= startMs && ms < endMs;
  }

  Duration get end => Duration(milliseconds: endMs);

  /// Stable identity for once-per-session skip tracking.
  ///
  /// Derived from the segment's own values rather than a server id, so it stays
  /// stable across a refetch and costs nothing extra on the wire.
  String get key => '${type.name}:$startMs:$endMs';

  /// Whether this segment is worth offering at all.
  ///
  /// An unrecognised type means the server knows a segment kind this build does
  /// not, and a zero-or-negative span is not skippable.
  bool get actionable => type != SegmentType.unknown && endMs > startMs;

  String get label {
    switch (type) {
      case SegmentType.intro:
        return 'Skip Intro';
      case SegmentType.credits:
        return 'Skip Credits';
      case SegmentType.unknown:
        return 'Skip';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MediaSegment &&
      other.type == type &&
      other.startMs == startMs &&
      other.endMs == endMs;

  @override
  int get hashCode => Object.hash(type, startMs, endMs);

  @override
  String toString() => 'MediaSegment($key)';
}
