import '../../../core/sources/source.dart';
import '../../../domain/models/download.dart';

/// Where tapping a download goes. `fileId=offline` tells the player screen to
/// resolve the local file instead of asking the server for a stream; a
/// source's route also puts it behind that source's lock.
String downloadedPlayLocation(DownloadedMedia media) {
  if (media.source == SourceId.legacyMydia) {
    final title = Uri.encodeComponent(media.title);
    if (media.type == MediaType.episode) {
      final season = media.seasonNumber;
      return '/player/episode/${media.mediaId}?fileId=offline&title=$title'
          '&showId=${media.showId ?? media.mediaId}'
          '${season != null ? '&seasonNumber=$season' : ''}';
    }
    return '/player/movie/${media.mediaId}?fileId=offline&title=$title';
  }
  return Uri(
    path:
        '/s/${media.source.value}/player/${Uri.encodeComponent(media.mediaId)}',
    queryParameters: {
      'kind': media.itemRef.kind.name,
      'fileId': 'offline',
      'title': media.title,
      if (media.showId != null) 'showId': media.showId!,
      if (media.seasonNumber != null) 'seasonNumber': '${media.seasonNumber}',
    },
  ).toString();
}
