/// Queueing a whole season from a source that downloads originals.
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/download_request.dart';
import '../../domain/sources/item.dart';
import '../../domain/sources/library.dart';
import '../downloads/bulk_download_helper.dart';
import '../downloads/download_service.dart';
import 'media_source.dart';
import 'original_download.dart';

/// Queues every episode of [season] as an original download, skipping the ones
/// already downloaded or in the queue. [optionId] is one the source's
/// `Downloadable.downloadOptions` offered for these episodes.
Future<BulkDownloadResult> queueSourceSeason({
  required MediaSource source,
  required ItemRef season,
  required DownloadService manager,
  required DownloadMetadata Function(ItemSummary episode) metadataFor,
  String optionId = originalOptionId,
}) async {
  final active = manager.getActiveDownloads();
  var queued = 0, skipped = 0, failed = 0;
  Cursor? cursor;
  do {
    final page = await source.children(season, cursor: cursor);
    for (final episode in page.items) {
      // An episode the listing names no version for has no file to fetch.
      if (episode.defaultVersionId == null ||
          manager.isDownloaded(episode.ref) ||
          active.any((t) => t.matches(episode.ref))) {
        skipped++;
        continue;
      }
      try {
        await manager.start(DownloadRequest(
          ref: episode.ref,
          optionId: optionId,
          metadata: metadataFor(episode),
        ));
        queued++;
      } catch (e) {
        debugPrint('Failed to queue download for ${episode.title}: $e');
        failed++;
      }
    }
    cursor = page.nextCursor;
  } while (cursor != null);
  return BulkDownloadResult(queued: queued, skipped: skipped, failed: failed);
}
