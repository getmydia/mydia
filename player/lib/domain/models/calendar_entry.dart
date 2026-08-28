import 'artwork.dart';
import 'media_file.dart';

/// Whether a calendar entry is an episode or a movie.
enum CalendarEntryKind { episode, movie }

/// One dated item on the calendar.
///
/// Playability is `files.isNotEmpty` and nothing else. The server sends no
/// separate flag, so the two cannot drift apart, and it never sends download
/// state: the calendar is a playback surface, not a library-management one.
class CalendarEntry {
  final String id;
  final CalendarEntryKind kind;
  final DateTime airDate;
  final String title;
  final int? seasonNumber;
  final int? episodeNumber;
  final String mediaItemId;
  final String mediaItemTitle;
  final Artwork? artwork;
  final List<MediaFile> files;

  const CalendarEntry({
    required this.id,
    required this.kind,
    required this.airDate,
    required this.title,
    required this.mediaItemId,
    required this.mediaItemTitle,
    this.seasonNumber,
    this.episodeNumber,
    this.artwork,
    this.files = const [],
  });

  bool get isPlayable => files.isNotEmpty;

  /// The day this entry belongs to, with no time component, for grouping.
  ///
  /// Deliberately not built on `presentation/screens/calendar/calendar_dates
  /// .dart`'s `truncateToDay`: this is `domain/`, which stays plain Dart with
  /// no dependency on `presentation/`, so the one-line truncation is repeated
  /// here rather than reaching up a layer for it.
  DateTime get day => DateTime(airDate.year, airDate.month, airDate.day);

  factory CalendarEntry.fromJson(Map<String, dynamic> json) {
    final rawFiles = json['files'] as List<dynamic>? ?? const [];
    final rawArtwork = json['artwork'] as Map<String, dynamic>?;

    return CalendarEntry(
      id: json['id'].toString(),
      kind: json['kind'] == 'MOVIE'
          ? CalendarEntryKind.movie
          : CalendarEntryKind.episode,
      airDate: DateTime.parse(json['airDate'] as String),
      title: json['title'] as String,
      seasonNumber: json['seasonNumber'] as int?,
      episodeNumber: json['episodeNumber'] as int?,
      mediaItemId: json['mediaItemId'].toString(),
      mediaItemTitle: json['mediaItemTitle'] as String,
      artwork: rawArtwork == null ? null : Artwork.fromJson(rawArtwork),
      files: rawFiles
          .map((e) => MediaFile.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
