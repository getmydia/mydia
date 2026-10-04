/// Routes out of a detail screen. Screens never build these strings
/// themselves, so a third-party screen cannot route into a Mydia id.
library;

import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../../../domain/models/media_file.dart';

String detailLocation(DetailTarget target) => switch (target) {
      MydiaTarget(kind: DetailKind.movie, :final id) => '/movie/$id',
      MydiaTarget(kind: DetailKind.show || DetailKind.season, :final id) =>
        '/show/$id',
      MydiaTarget(kind: DetailKind.episode, :final id) => '/episode/$id',
    };

String moviePlayerLocation(MovieView movie, MediaFile file) =>
    switch (movie.target) {
      MydiaTarget(:final id) => '/player/movie/$id?fileId=${file.id}'
          '&title=${Uri.encodeComponent(movie.title)}',
    };

String episodePlayerLocation(
  EpisodeView episode,
  MediaFile file, {
  int? resumeSeconds,
}) {
  final showTarget = episode.showTarget;
  return switch (episode.target) {
    MydiaTarget(:final id) => '/player/episode/$id?fileId=${file.id}'
        '&title=${Uri.encodeComponent(episode.fullTitle)}'
        '${showTarget == null ? '' : '&showId=${showTarget.id}'}'
        '&seasonNumber=${episode.seasonNumber}'
        '${resumeSeconds == null ? '' : '&resume=$resumeSeconds'}',
  };
}
