import 'package:flutter/foundation.dart';

import '../../domain/models/download_request.dart';
import '../../domain/models/episode.dart';
import '../../domain/sources/item.dart';
import 'download_service.dart';
import '../sources/source.dart';
import 'mydia_download_metadata.dart';

/// Result of a bulk download operation.
class BulkDownloadResult {
  final int queued;
  final int skipped;
  final int failed;

  const BulkDownloadResult({
    required this.queued,
    required this.skipped,
    required this.failed,
  });

  int get total => queued + skipped + failed;
}

/// Queues downloads for a list of episodes, skipping already downloaded
/// or in-queue episodes.
///
/// Returns a [BulkDownloadResult] with counts of queued, skipped, and failed.
Future<BulkDownloadResult> startBulkEpisodeDownloads({
  required List<Episode> episodes,
  required String resolution,
  required SourceId sourceId,
  required String showId,
  required String showTitle,
  required String? showPosterUrl,
  required DownloadService downloadManager,
  required bool Function(String mediaId) isMediaDownloaded,
  required bool Function(String mediaId) isMediaInQueue,
}) async {
  int queued = 0;
  int skipped = 0;
  int failed = 0;

  for (final episode in episodes) {
    // Skip already downloaded or queued episodes
    if (isMediaDownloaded(episode.id) || isMediaInQueue(episode.id)) {
      skipped++;
      continue;
    }

    try {
      await downloadManager.start(DownloadRequest(
        ref: ItemRef(
            sourceId: sourceId, kind: ItemKind.episode, externalId: episode.id),
        optionId: resolution,
        metadata: mydiaEpisodeMetadata(
          episode,
          showId: showId,
          showTitle: showTitle,
          showPosterUrl: showPosterUrl,
        ),
      ));
      queued++;
    } catch (e) {
      debugPrint('Failed to queue download for ${episode.episodeCode}: $e');
      failed++;
    }
  }

  return BulkDownloadResult(queued: queued, skipped: skipped, failed: failed);
}
