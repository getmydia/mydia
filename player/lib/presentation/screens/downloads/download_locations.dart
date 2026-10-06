import '../../../domain/models/download.dart';

/// Where tapping a download goes. `fileId=offline` tells the player screen to
/// resolve the local file instead of asking the server for a stream; a
/// source's route also puts it behind that source's lock.
String downloadedPlayLocation(DownloadedMedia media) {
  return Uri(
    // Raw id: Uri(path:) does the encoding, like the sibling route builders.
    path: '/s/${media.source.value}/player/${media.mediaId}',
    queryParameters: {
      'kind': media.itemRef.kind.name,
      'fileId': 'offline',
      'title': media.title,
      if (media.showId != null) 'showId': media.showId!,
      if (media.seasonNumber != null) 'seasonNumber': '${media.seasonNumber}',
    },
  ).toString();
}
