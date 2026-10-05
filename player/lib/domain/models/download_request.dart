/// What a screen asks the download service for.
library;

import '../../core/sources/source.dart';
import '../sources/item.dart';
import 'download.dart';

/// The home Mydia login's id for [id], for the screens that predate sources.
ItemRef homeMydiaRef(ItemKind kind, String id) =>
    ItemRef(sourceId: SourceId.legacyMydia, kind: kind, externalId: id);

/// What the Downloads screen shows for an item, captured when the download
/// starts so it is there offline.
///
/// The art fields hold a URL for home Mydia and an `ArtworkRef.path` for
/// every other source; the pipeline turns them into local files at the end.
class DownloadMetadata {
  const DownloadMetadata({
    required this.title,
    required this.mediaType,
    this.posterUrl,
    this.backdropUrl,
    this.thumbnailUrl,
    this.overview,
    this.runtime,
    this.genres,
    this.rating,
    this.year,
    this.contentRating,
    this.seasonNumber,
    this.episodeNumber,
    this.showId,
    this.showTitle,
    this.showPosterUrl,
    this.airDate,
  });

  final String title;
  final MediaType mediaType;
  final String? posterUrl;
  final String? backdropUrl;
  final String? thumbnailUrl;
  final String? overview;
  final int? runtime;
  final List<String>? genres;
  final double? rating;
  final int? year;
  final String? contentRating;
  final int? seasonNumber;
  final int? episodeNumber;
  final String? showId;
  final String? showTitle;
  final String? showPosterUrl;
  final String? airDate;
}

class DownloadRequest {
  const DownloadRequest({
    required this.ref,
    required this.optionId,
    required this.metadata,
    this.expectedBytes,
  });

  final ItemRef ref;

  /// `DownloadOption.resolution`: `original`, or a Mydia quality.
  final String optionId;

  final DownloadMetadata metadata;

  final int? expectedBytes;
}
