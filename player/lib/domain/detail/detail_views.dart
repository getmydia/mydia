/// What the movie, show and episode screens render, whichever server
/// answered. A screen offers an action only when the view lists the matching
/// [DetailFeature].
library;

import 'package:flutter/foundation.dart';

import '../models/media_file.dart';
import '../models/progress.dart';
import '../models/watch_status.dart';
import 'detail_art.dart';
import 'detail_target.dart';

/// What a screen may offer beyond showing the item.
enum DetailFeature {
  watched,
  favorite,

  /// Download to this device.
  download,

  /// The source's media info sheet.
  mediaInfo,

  /// Download a whole season.
  seasonDownload,
}

const _monthAbbreviations = [
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

/// Formats [lastWatchedAt] for the watched badge.
///
/// [now] is a parameter rather than an internal `DateTime.now()` so the
/// year-elision branch is testable without depending on the wall clock.
/// Returns `''` when there is nothing to show, which is the caller's cue
/// to render the badge without a date.
String formatWatchedAt(String? lastWatchedAt, DateTime now) {
  if (lastWatchedAt == null) return '';

  final parsed = DateTime.tryParse(lastWatchedAt);
  if (parsed == null) return '';

  final local = parsed.toLocal();
  final label = '${_monthAbbreviations[local.month - 1]} ${local.day}';
  return local.year == now.year ? label : '$label, ${local.year}';
}

String _runtime(int? minutes) {
  if (minutes == null) return '';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (hours == 0) return '${rest}m';
  return rest > 0 ? '${hours}h ${rest}m' : '${hours}h';
}

@immutable
class CastView {
  const CastView({required this.name, this.character, this.photo});

  final String name;
  final String? character;
  final DetailArt? photo;
}

@immutable
class SeasonView {
  const SeasonView({
    required this.number,
    this.target,
    this.watchStatus,
    this.hasFiles = true,
  });

  final int number;

  /// The server's own season, when it names one.
  final DetailTarget? target;
  final WatchStatus? watchStatus;

  /// False for a season with nothing to play, which the chips skip.
  final bool hasFiles;
}

@immutable
class EpisodeView {
  const EpisodeView({
    required this.target,
    required this.showTitle,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.title,
    this.showTarget,
    this.overview,
    this.airDate,
    this.runtime,
    this.still,
    this.showBackdrop,
    this.showPoster,
    this.progress,
    this.files = const [],
    this.hasFile = true,
    this.features = const {},
  });

  final DetailTarget target;
  final DetailTarget? showTarget;
  final String showTitle;
  final int seasonNumber;
  final int episodeNumber;
  final String title;
  final String? overview;
  final String? airDate;

  /// Minutes.
  final int? runtime;
  final DetailArt? still;
  final DetailArt? showBackdrop;
  final DetailArt? showPoster;
  final Progress? progress;
  final List<MediaFile> files;
  final bool hasFile;
  final Set<DetailFeature> features;

  /// The id the show screen's selection state holds.
  String get id => target.id;

  bool get watched => progress?.watched ?? false;

  String get episodeCode => 'S${seasonNumber.toString().padLeft(2, '0')}'
      'E${episodeNumber.toString().padLeft(2, '0')}';

  String get runtimeDisplay => _runtime(runtime);

  String get fullTitle => '$showTitle - $episodeCode';

  EpisodeView copyWith({
    Progress? progress,
    bool clearProgress = false,
    List<MediaFile>? files,
  }) =>
      EpisodeView(
        target: target,
        showTarget: showTarget,
        showTitle: showTitle,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
        title: title,
        overview: overview,
        airDate: airDate,
        runtime: runtime,
        still: still,
        showBackdrop: showBackdrop,
        showPoster: showPoster,
        progress: clearProgress ? null : (progress ?? this.progress),
        files: files ?? this.files,
        hasFile: hasFile,
        features: features,
      );
}

@immutable
class MovieView {
  const MovieView({
    required this.target,
    required this.title,
    this.year,
    this.overview,
    this.runtime,
    this.genres = const [],
    this.contentRating,
    this.rating,
    this.backdrop,
    this.poster,
    this.progress,
    this.files = const [],
    this.isFavorite = false,
    this.trailerUrl,
    this.cast = const [],
    this.features = const {},
  });

  final DetailTarget target;
  final String title;
  final int? year;
  final String? overview;

  /// Minutes.
  final int? runtime;
  final List<String> genres;
  final String? contentRating;

  /// Zero to ten.
  final double? rating;
  final DetailArt? backdrop;
  final DetailArt? poster;
  final Progress? progress;
  final List<MediaFile> files;
  final bool isFavorite;
  final String? trailerUrl;
  final List<CastView> cast;
  final Set<DetailFeature> features;

  bool get isWatched => progress?.watched ?? false;

  bool get hasResumableProgress {
    final current = progress;
    return current != null && !current.watched && current.percentage > 0;
  }

  String get watchedAtDisplay =>
      formatWatchedAt(progress?.lastWatchedAt, DateTime.now());

  String get yearDisplay => year?.toString() ?? '';

  String get runtimeDisplay => _runtime(runtime);

  String get ratingDisplay => rating?.toStringAsFixed(1) ?? '';

  MovieView copyWith({
    Progress? progress,
    bool clearProgress = false,
    bool? isFavorite,
    String? trailerUrl,
    List<CastView>? cast,
  }) =>
      MovieView(
        target: target,
        title: title,
        year: year,
        overview: overview,
        runtime: runtime,
        genres: genres,
        contentRating: contentRating,
        rating: rating,
        backdrop: backdrop,
        poster: poster,
        progress: clearProgress ? null : (progress ?? this.progress),
        files: files,
        isFavorite: isFavorite ?? this.isFavorite,
        trailerUrl: trailerUrl ?? this.trailerUrl,
        cast: cast ?? this.cast,
        features: features,
      );
}

@immutable
class ShowView {
  const ShowView({
    required this.target,
    required this.title,
    this.year,
    this.overview,
    this.status,
    this.genres = const [],
    this.contentRating,
    this.rating,
    this.backdrop,
    this.poster,
    this.seasons = const [],
    this.nextUpEpisodeId,
    this.nextUpSeasonNumber,
    this.isFavorite = false,
    this.trailerUrl,
    this.cast = const [],
    this.features = const {},
  });

  final DetailTarget target;
  final String title;
  final int? year;
  final String? overview;

  /// As the server words it ("Continuing", "Ended"). Null hides the chip.
  final String? status;
  final List<String> genres;
  final String? contentRating;
  final double? rating;
  final DetailArt? backdrop;
  final DetailArt? poster;
  final List<SeasonView> seasons;

  /// The episode the hero starts on, when the server names one.
  final String? nextUpEpisodeId;
  final int? nextUpSeasonNumber;
  final bool isFavorite;
  final String? trailerUrl;
  final List<CastView> cast;
  final Set<DetailFeature> features;

  String get yearDisplay => year?.toString() ?? '';

  String get ratingDisplay => rating?.toStringAsFixed(1) ?? '';

  ShowView copyWith({
    bool? isFavorite,
    String? nextUpEpisodeId,
    int? nextUpSeasonNumber,
    String? trailerUrl,
    List<CastView>? cast,
  }) =>
      ShowView(
        target: target,
        title: title,
        year: year,
        overview: overview,
        status: status,
        genres: genres,
        contentRating: contentRating,
        rating: rating,
        backdrop: backdrop,
        poster: poster,
        seasons: seasons,
        nextUpEpisodeId: nextUpEpisodeId ?? this.nextUpEpisodeId,
        nextUpSeasonNumber: nextUpSeasonNumber ?? this.nextUpSeasonNumber,
        isFavorite: isFavorite ?? this.isFavorite,
        trailerUrl: trailerUrl ?? this.trailerUrl,
        cast: cast ?? this.cast,
        features: features,
      );
}
