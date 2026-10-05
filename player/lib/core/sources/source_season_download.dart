/// Queueing a whole season from a source that downloads originals.
library;

import '../../domain/models/download_request.dart';
import '../../domain/sources/item.dart';
import '../../domain/sources/library.dart';
import '../downloads/bulk_download_helper.dart';
import '../downloads/download_service.dart';
import 'media_source.dart';
import 'original_download.dart';

/// Queues every episode of [season] as an original download, skipping the ones
/// already downloaded or in the queue.
Future<BulkDownloadResult> queueSourceSeason({
  required MediaSource source,
  required ItemRef season,
  required DownloadService manager,
  required DownloadMetadata Function(ItemSummary episode) metadataFor,
}) async {
  final queuedAlready =
      manager.getActiveDownloads().map((t) => t.itemRef).toSet();
  var queued = 0, skipped = 0, failed = 0;
  Cursor? cursor;
  do {
    final page = await source.children(season, cursor: cursor);
    for (final episode in page.items) {
      if (manager.isDownloaded(episode.ref) ||
          queuedAlready.contains(episode.ref)) {
        skipped++;
        continue;
      }
      try {
        await manager.start(DownloadRequest(
          ref: episode.ref,
          optionId: originalOptionId,
          metadata: metadataFor(episode),
        ));
        queued++;
      } catch (_) {
        failed++;
      }
    }
    cursor = page.nextCursor;
  } while (cursor != null);
  return BulkDownloadResult(queued: queued, skipped: skipped, failed: failed);
}
