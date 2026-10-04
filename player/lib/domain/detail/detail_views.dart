/// What the movie, show and episode screens render, whichever server
/// answered. Mydia-only actions read the original model from `mydia`, and
/// only when the view lists the matching [DetailFeature].
library;

import 'package:flutter/foundation.dart';

import '../models/episode.dart';
import '../models/episode_detail.dart';
import '../models/media_file.dart';
import '../models/movie_detail.dart';
import '../models/progress.dart';
import '../models/show_detail.dart';
import '../models/watch_status.dart';
import 'detail_art.dart';
import 'detail_target.dart';

/// What a screen may offer beyond showing the item.
enum DetailFeature {
  watched,
  favorite,

  /// Mydia downloads. Reads `mydia`.
  download,

  /// Mydia's media info sheet. Reads `mydia`.
  mediaInfo,

  /// Mydia's per-season and whole-show download menu.
  seasonDownload,
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

  /// The server's own season, when it has one (Plex, Jellyfin). Null for
  /// Mydia, which addresses a season by show and number.
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
    this.mydia,
    this.mydiaDetail,
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

  /// The Mydia episode behind a season-list entry, for the download button.
  final Episode? mydia;

  /// The Mydia episode behind the episode screen, for its download button.
  final EpisodeDetail? mydiaDetail;

  /// The id the show screen's selection state holds.
  String get id => target.id;

  bool get watched => progress?.watched ?? false;

  String get episodeCode => 'S${seasonNumber.toString().padLeft(2, '0')}'
      'E${episodeNumber.toString().padLeft(2, '0')}';

  String get runtimeDisplay => _runtime(runtime);

  String get fullTitle => '$showTitle - $episodeCode';
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
    this.mydia,
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
  final MovieDetail? mydia;

  bool get isWatched => progress?.watched ?? false;

  bool get hasResumableProgress {
    final current = progress;
    return current != null && !current.watched && current.percentage > 0;
  }

  String get watchedAtDisplay =>
      MovieDetail.formatWatchedAt(progress?.lastWatchedAt, DateTime.now());

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
        mydia: mydia,
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
    this.mydia,
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
  final ShowDetail? mydia;

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
        mydia: mydia,
      );
}
