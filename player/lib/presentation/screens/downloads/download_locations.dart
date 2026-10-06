import '../../../domain/models/download.dart';
import '../detail/detail_links.dart';

/// Where tapping a download goes. `fileId=offline` tells the player screen to
/// resolve the local file instead of asking the server for a stream; a
/// source's route also puts it behind that source's lock.
String downloadedPlayLocation(DownloadedMedia media) => sourcePlayerLocation(
      media.itemRef,
      fileId: 'offline',
      title: media.title,
      extra: {
        if (media.showId != null) 'showId': media.showId!,
        if (media.seasonNumber != null) 'seasonNumber': '${media.seasonNumber}',
      },
    );
