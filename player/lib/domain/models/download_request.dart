/// What a screen asks the download service for.
library;

import '../sources/item.dart';
import 'download.dart';

/// What the Downloads screen shows for an item, captured when the download
/// starts so it is there offline.
///
/// The art fields hold a URL for art that is one (`UrlArt`) and an
/// `ArtworkRef.path` otherwise; the pipeline turns them into local files at the end.
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

  /// This metadata with the series it belongs to filled in where it has none.
  /// A title that did not name the series now leads with it.
  DownloadMetadata withShow({
    String? showId,
    String? showTitle,
    String? showPosterUrl,
  }) =>
      DownloadMetadata(
        title: this.showTitle == null && showTitle != null
            ? '$showTitle - $title'
            : title,
        mediaType: mediaType,
        posterUrl: posterUrl,
        backdropUrl: backdropUrl,
        thumbnailUrl: thumbnailUrl,
        overview: overview,
        runtime: runtime,
        genres: genres,
        rating: rating,
        year: year,
        contentRating: contentRating,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
        showId: this.showId ?? showId,
        showTitle: this.showTitle ?? showTitle,
        showPosterUrl: this.showPosterUrl ?? showPosterUrl,
        airDate: airDate,
      );
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
