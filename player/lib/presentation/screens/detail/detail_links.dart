/// Routes out of a detail screen. Screens never build these strings
/// themselves, so a third-party screen cannot route into a Mydia id.
library;

import '../../../core/sources/source.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../../../domain/models/media_file.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';

/// The per-source pages that list items without a library behind them.
enum SourceListing {
  collections('collections'),
  calendar('calendar'),
  favorites('favorites'),
  unwatched('unwatched'),
  recentlyAdded('recently-added'),
  continueWatching('continue-watching');

  const SourceListing(this.segment);
  final String segment;
}

/// Every segment goes through [Uri] so ids with `/` or spaces stay one segment.
String _sourcePath(SourceId id, List<String> rest,
        {Map<String, String>? query}) =>
    Uri(
      pathSegments: ['', 's', id.value, ...rest],
      queryParameters: query == null || query.isEmpty ? null : query,
    ).toString();

String sourceHomeLocation(SourceId id) => _sourcePath(id, const []);

String sourceLibraryLocation(LibraryRef library) =>
    _sourcePath(library.sourceId, ['library', library.id]);

String sourceSearchLocation(SourceId id, {String? query}) =>
    _sourcePath(id, const ['search'], query: {if (query != null) 'q': query});

String sourceListingLocation(SourceId id, SourceListing listing) =>
    _sourcePath(id, [listing.segment]);

String collectionLocation(SourceId id, String collectionId) =>
    _sourcePath(id, ['collection', collectionId]);

String filterLocation(SourceId id, String filterId) =>
    _sourcePath(id, ['filter', filterId]);

/// Kinds with a detail screen open it; videos and folders open the generic
/// item route.
String sourceItemLocation(ItemRef ref) => detailKindOf(ref.kind) != null
    ? detailLocation(SourceTarget(ref))
    : _sourcePath(ref.sourceId, ['item', ref.kind.name, ref.externalId]);

/// The source player route. Credentials never ride along: the player asks the
/// source for the stream.
String sourcePlayerLocation(
  ItemRef ref, {
  String? fileId,
  String? title,
  Map<String, String> extra = const {},
}) =>
    _sourcePath(ref.sourceId, [
      'player',
      ref.externalId
    ], query: {
      'kind': ref.kind.name,
      if (fileId != null) 'fileId': fileId,
      if (title != null) 'title': title,
      ...extra,
    });

String detailLocation(DetailTarget target) => switch (target) {
      MydiaTarget(kind: DetailKind.movie, :final id) => '/movie/$id',
      MydiaTarget(kind: DetailKind.show || DetailKind.season, :final id) =>
        '/show/$id',
      MydiaTarget(kind: DetailKind.episode, :final id) => '/episode/$id',
      SourceTarget(:final ref) =>
        _sourcePath(ref.sourceId, [_detailSegment(ref.kind), ref.externalId]),
    };

String _detailSegment(ItemKind kind) => switch (kind) {
      ItemKind.movie => 'movie',
      ItemKind.show => 'show',
      ItemKind.season => 'season',
      _ => 'episode',
    };

String moviePlayerLocation(MovieView movie, MediaFile file) =>
    switch (movie.target) {
      MydiaTarget(:final id) => '/player/movie/$id?fileId=${file.id}'
          '&title=${Uri.encodeComponent(movie.title)}',
      SourceTarget(:final ref) =>
        sourcePlayerLocation(ref, fileId: file.id, title: movie.title),
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
    SourceTarget(:final ref) => sourcePlayerLocation(
        ref,
        fileId: file.id,
        title: episode.fullTitle,
        extra: {
          if (showTarget != null) 'showId': showTarget.id,
          'seasonNumber': '${episode.seasonNumber}',
          if (resumeSeconds != null) 'resume': '$resumeSeconds',
        },
      ),
  };
}
