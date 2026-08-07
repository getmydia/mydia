import 'artwork.dart';
import 'season_info.dart';
import 'next_episode.dart';
import 'show_next_up.dart';
import 'cast_member.dart';
import 'recently_added_item.dart';

class ShowDetail {
  final String id;
  final String title;
  final String? originalTitle;
  final int? year;
  final String? overview;
  final String? status;
  final List<String> genres;
  final String? contentRating;
  final double? rating;
  final String? tmdbId;
  final String? imdbId;
  final String? category;
  final bool monitored;
  final String? addedAt;
  final int seasonCount;
  final int episodeCount;
  final Artwork artwork;
  final List<SeasonInfo> seasons;
  final NextEpisode? nextEpisode;
  final ShowNextUp? nextUp;
  final bool isFavorite;
  final List<CastMember> cast;
  final String? trailerUrl;
  final List<RecentlyAddedItem> similar;

  const ShowDetail({
    required this.id,
    required this.title,
    this.originalTitle,
    this.year,
    this.overview,
    this.status,
    this.genres = const [],
    this.contentRating,
    this.rating,
    this.tmdbId,
    this.imdbId,
    this.category,
    required this.monitored,
    this.addedAt,
    required this.seasonCount,
    required this.episodeCount,
    required this.artwork,
    this.seasons = const [],
    this.nextEpisode,
    this.nextUp,
    required this.isFavorite,
    this.cast = const [],
    this.trailerUrl,
    this.similar = const [],
  });

  factory ShowDetail.fromJson(Map<String, dynamic> json) {
    return ShowDetail(
      id: json['id'].toString(),
      title: json['title'] as String,
      originalTitle: json['originalTitle'] as String?,
      year: json['year'] as int?,
      overview: json['overview'] as String?,
      status: json['status'] as String?,
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
      seasonCount: json['seasonCount'] as int? ?? 0,
      episodeCount: json['episodeCount'] as int? ?? 0,
      artwork: json['artwork'] != null
          ? Artwork.fromJson(json['artwork'] as Map<String, dynamic>)
          : const Artwork(),
      seasons: (json['seasons'] as List<dynamic>?)
              ?.map((e) => SeasonInfo.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      nextEpisode: json['nextEpisode'] != null
          ? NextEpisode.fromJson(json['nextEpisode'] as Map<String, dynamic>)
          : null,
      nextUp: json['nextUp'] != null
          ? ShowNextUp.fromJson(json['nextUp'] as Map<String, dynamic>)
          : null,
      isFavorite: json['isFavorite'] as bool? ?? false,
      cast: (json['cast'] as List<dynamic>?)
              ?.map((e) => CastMember.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      trailerUrl: json['trailerUrl'] as String?,
      similar: (json['similar'] as List<dynamic>?)
              ?.map(
                  (e) => RecentlyAddedItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  String get yearDisplay => year?.toString() ?? '';

  String get ratingDisplay {
    if (rating == null) return '';
    return rating!.toStringAsFixed(1);
  }

  String get statusDisplay => status ?? '';
}
