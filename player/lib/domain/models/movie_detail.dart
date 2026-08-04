import 'artwork.dart';
import 'progress.dart';
import 'media_file.dart';

class MovieDetail {
  final String id;
  final String title;
  final String? originalTitle;
  final int? year;
  final String? overview;
  final int? runtime;
  final List<String> genres;
  final String? contentRating;
  final double? rating;
  final String? tmdbId;
  final String? imdbId;
  final String? category;
  final bool monitored;
  final String? addedAt;
  final Artwork artwork;
  final Progress? progress;
  final List<MediaFile> files;
  final bool isFavorite;

  const MovieDetail({
    required this.id,
    required this.title,
    this.originalTitle,
    this.year,
    this.overview,
    this.runtime,
    this.genres = const [],
    this.contentRating,
    this.rating,
    this.tmdbId,
    this.imdbId,
    this.category,
    required this.monitored,
    this.addedAt,
    required this.artwork,
    this.progress,
    this.files = const [],
    required this.isFavorite,
  });

  factory MovieDetail.fromJson(Map<String, dynamic> json) {
    return MovieDetail(
      id: json['id'].toString(),
      title: json['title'] as String,
      originalTitle: json['originalTitle'] as String?,
      year: json['year'] as int?,
      overview: json['overview'] as String?,
      runtime: json['runtime'] as int?,
      genres: (json['genres'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      contentRating: json['contentRating'] as String?,
      rating: (json['rating'] as num?)?.toDouble(),
      tmdbId: json['tmdbId']?.toString(),
      imdbId: json['imdbId'] as String?,
      category: json['category'] as String?,
      monitored: json['monitored'] as bool? ?? false,
      addedAt: json['addedAt'] as String?,
      artwork: json['artwork'] != null
          ? Artwork.fromJson(json['artwork'] as Map<String, dynamic>)
          : const Artwork(),
      progress: json['progress'] != null
          ? Progress.fromJson(json['progress'] as Map<String, dynamic>)
          : null,
      files: (json['files'] as List<dynamic>?)
              ?.map((e) => MediaFile.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      isFavorite: json['isFavorite'] as bool? ?? false,
    );
  }

  static const List<String> _monthAbbreviations = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// Returns a copy with the UI-mutable fields replaced.
  ///
  /// [clearProgress] exists because marking a movie unwatched must null the
  /// progress row outright, mirroring the server deleting it. A plain
  /// `progress ?? this.progress` merge cannot express that. Same shape as
  /// `Episode.copyWith`.
  MovieDetail copyWith({
    Progress? progress,
    bool? isFavorite,
    bool clearProgress = false,
  }) {
    return MovieDetail(
      id: id,
      title: title,
      originalTitle: originalTitle,
      year: year,
      overview: overview,
      runtime: runtime,
      genres: genres,
      contentRating: contentRating,
      rating: rating,
      tmdbId: tmdbId,
      imdbId: imdbId,
      category: category,
      monitored: monitored,
      addedAt: addedAt,
      artwork: artwork,
      progress: clearProgress ? null : (progress ?? this.progress),
      files: files,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }

  /// Whether this movie is marked watched. A missing progress row reads as
  /// unwatched, which is what the server means by deleting it.
  bool get isWatched => progress?.watched ?? false;

  /// Whether there is partial playback worth showing a progress bar for.
  bool get hasResumableProgress {
    final current = progress;
    return current != null && !current.watched && current.percentage > 0;
  }

  /// Formats [lastWatchedAt] for the watched badge.
  ///
  /// [now] is a parameter rather than an internal `DateTime.now()` so the
  /// year-elision branch is testable without depending on the wall clock.
  /// Returns `''` when there is nothing to show, which is the caller's cue
  /// to render the badge without a date.
  static String formatWatchedAt(String? lastWatchedAt, DateTime now) {
    if (lastWatchedAt == null) return '';

    final parsed = DateTime.tryParse(lastWatchedAt);
    if (parsed == null) return '';

    final local = parsed.toLocal();
    final label = '${_monthAbbreviations[local.month - 1]} ${local.day}';
    return local.year == now.year ? label : '$label, ${local.year}';
  }

  String get watchedAtDisplay =>
      formatWatchedAt(progress?.lastWatchedAt, DateTime.now());

  String get yearDisplay => year?.toString() ?? '';

  String get runtimeDisplay {
    if (runtime == null) return '';
    final hours = runtime! ~/ 60;
    final minutes = runtime! % 60;
    if (hours == 0) return '${minutes}m';
    return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  }

  String get ratingDisplay {
    if (rating == null) return '';
    return rating!.toStringAsFixed(1);
  }
}
