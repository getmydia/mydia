/// What a download stores about an item that is known only by its listing
/// entry, as in a collection sync. Art is the server path, resolved with
/// credentials when the download saves it.
library;

import '../../domain/models/download.dart';
import '../../domain/models/download_request.dart';
import '../../domain/sources/item.dart';

DownloadMetadata summaryDownloadMetadata(ItemSummary item) {
  final runtime =
      item.durationSeconds == null ? null : item.durationSeconds! ~/ 60;
  if (item.ref.kind != ItemKind.episode) {
    return DownloadMetadata(
      title: item.title,
      mediaType: MediaType.movie,
      posterUrl: item.poster?.path,
      backdropUrl: item.backdrop?.path,
      overview: item.overview,
      runtime: runtime,
      year: item.year,
    );
  }
  final season = (item.parentIndex ?? 0).toString().padLeft(2, '0');
  final episode = (item.index ?? 0).toString().padLeft(2, '0');
  final show = item.showTitle;
  return DownloadMetadata(
    title:
        '${show == null ? '' : '$show - '}S${season}E$episode: ${item.title}',
    mediaType: MediaType.episode,
    posterUrl: item.poster?.path,
    thumbnailUrl: item.poster?.path,
    backdropUrl: item.backdrop?.path,
    overview: item.overview,
    runtime: runtime,
    seasonNumber: item.parentIndex,
    episodeNumber: item.index,
    showTitle: show,
    airDate: item.airDate,
  );
}
