/// What the Downloads screen shows for a home Mydia movie or episode, shared by
/// the single and bulk download flows.
library;

import '../../domain/models/download.dart';
import '../../domain/models/download_request.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/movie_detail.dart';

DownloadMetadata mydiaMovieMetadata(MovieDetail movie) => DownloadMetadata(
      title: movie.title,
      mediaType: MediaType.movie,
      posterUrl: movie.artwork.posterUrl,
      overview: movie.overview,
      runtime: movie.runtime,
      genres: movie.genres,
      rating: movie.rating,
      backdropUrl: movie.artwork.backdropUrl,
      year: movie.year,
      contentRating: movie.contentRating,
    );

DownloadMetadata mydiaEpisodeMetadata(
  Episode episode, {
  String? showId,
  required String showTitle,
  String? showPosterUrl,
}) =>
    DownloadMetadata(
      title: '$showTitle - ${episode.episodeCode}: ${episode.title}',
      mediaType: MediaType.episode,
      posterUrl: episode.thumbnailUrl,
      overview: episode.overview,
      runtime: episode.runtime,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
      showId: showId,
      showTitle: showTitle,
      showPosterUrl: showPosterUrl,
      thumbnailUrl: episode.thumbnailUrl,
      airDate: episode.airDate,
    );
