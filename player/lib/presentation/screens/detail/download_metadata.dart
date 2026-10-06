/// What a download stores about an item, built from the detail views every
/// source maps to.
library;

import '../../../domain/detail/detail_art.dart';
import '../../../domain/detail/detail_views.dart';
import '../../../domain/models/download.dart';
import '../../../domain/models/download_request.dart';

/// What a download stores for a picture: the URL for a `UrlArt`, the
/// server path for a source's artwork (resolved with credentials at save time).
String? artKey(DetailArt? art) => switch (art) {
      UrlArt(:final url) => url,
      SourceArt(:final ref) => ref.path,
      null => null,
    };

DownloadMetadata movieDownloadMetadata(MovieView movie) => DownloadMetadata(
      title: movie.title,
      mediaType: MediaType.movie,
      posterUrl: artKey(movie.poster),
      backdropUrl: artKey(movie.backdrop),
      overview: movie.overview,
      runtime: movie.runtime,
      genres: movie.genres,
      rating: movie.rating,
      year: movie.year,
      contentRating: movie.contentRating,
    );

DownloadMetadata episodeDownloadMetadata(EpisodeView episode) {
  final showTarget = episode.showTarget;
  return DownloadMetadata(
    title: '${episode.showTitle} - ${episode.episodeCode}: ${episode.title}',
    mediaType: MediaType.episode,
    posterUrl: artKey(episode.still ?? episode.showPoster),
    thumbnailUrl: artKey(episode.still),
    backdropUrl: artKey(episode.showBackdrop),
    overview: episode.overview,
    runtime: episode.runtime,
    seasonNumber: episode.seasonNumber,
    episodeNumber: episode.episodeNumber,
    showId: showTarget?.id,
    showTitle: episode.showTitle,
    showPosterUrl: artKey(episode.showPoster),
    airDate: episode.airDate,
  );
}
