/// Routes out of a detail screen. Screens never build these strings
/// themselves, so a third-party screen cannot route into a Mydia id.
library;

import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../../../domain/models/media_file.dart';
import '../../../domain/sources/item.dart';

String detailLocation(DetailTarget target) => switch (target) {
      MydiaTarget(kind: DetailKind.movie, :final id) => '/movie/$id',
      MydiaTarget(kind: DetailKind.show || DetailKind.season, :final id) =>
        '/show/$id',
      MydiaTarget(kind: DetailKind.episode, :final id) => '/episode/$id',
      SourceTarget(:final ref) => '/s/${ref.sourceId.value}'
          '/${_detailSegment(ref.kind)}/${Uri.encodeComponent(ref.externalId)}',
    };

String _detailSegment(ItemKind kind) => switch (kind) {
      ItemKind.movie => 'movie',
      ItemKind.show => 'show',
      ItemKind.season => 'season',
      _ => 'episode',
    };

/// The source player route. Credentials never ride along: the player asks the
/// source for the stream.
String _sourcePlayerLocation(ItemRef ref, Map<String, String> query) => Uri(
      pathSegments: ['', 's', ref.sourceId.value, 'player', ref.externalId],
      queryParameters: query,
    ).toString();

String moviePlayerLocation(MovieView movie, MediaFile file) =>
    switch (movie.target) {
      MydiaTarget(:final id) => '/player/movie/$id?fileId=${file.id}'
          '&title=${Uri.encodeComponent(movie.title)}',
      SourceTarget(:final ref) => _sourcePlayerLocation(ref, {
          'kind': ref.kind.name,
          'fileId': file.id,
          'title': movie.title,
        }),
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
    SourceTarget(:final ref) => _sourcePlayerLocation(ref, {
        'kind': ref.kind.name,
        'fileId': file.id,
        'title': episode.fullTitle,
        if (showTarget != null) 'showId': showTarget.id,
        'seasonNumber': '${episode.seasonNumber}',
        if (resumeSeconds != null) 'resume': '$resumeSeconds',
      }),
  };
}
