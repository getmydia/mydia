/// Service for syncing collection items for offline download.
///
/// Orchestrates downloading all movies and TV show episodes
/// in a collection, skipping items already downloaded or queued.
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/download.dart';
import '../../domain/models/download_request.dart';
import '../../domain/sources/item.dart';
import '../../domain/sources/library.dart';
import '../../domain/sources/source_error.dart';
import '../sources/capabilities.dart';
import '../sources/media_source.dart';
import '../sources/source_season_download.dart';
import 'download_service.dart';

/// Result of syncing a collection's items for download.
class CollectionSyncResult {
  final int moviesQueued;
  final int episodesQueued;
  final int skipped;
  final int failed;

  const CollectionSyncResult({
    required this.moviesQueued,
    required this.episodesQueued,
    required this.skipped,
    required this.failed,
  });

  int get totalQueued => moviesQueued + episodesQueued;
  bool get hasNewDownloads => totalQueued > 0;
}

/// Syncs all items in a collection for offline download.
///
/// A movie is started directly. A show is walked season by season through
/// the source. [optionId] is one the source offered for these items, and
/// [queue] is what is already queued, so nothing is queued twice.
Future<CollectionSyncResult> syncCollectionItems({
  required MediaSource source,
  required List<ItemSummary> items,
  required String optionId,
  required DownloadService manager,
  required List<DownloadTask> queue,
  required DownloadMetadata Function(ItemSummary item) metadataFor,
}) async {
  var moviesQueued = 0, episodesQueued = 0, skipped = 0, failed = 0;

  for (final item in items) {
    switch (item.ref.kind) {
      case ItemKind.movie:
        if (manager.isDownloaded(item.ref) ||
            queue.any((t) => t.matches(item.ref))) {
          skipped++;
          continue;
        }
        try {
          // A collection listing does not name versions, so ask the source
          // before queueing something with no file.
          if (item.defaultVersionId == null &&
              (await source.item(item.ref)).versions.isEmpty) {
            skipped++;
            continue;
          }
          await manager.start(DownloadRequest(
            ref: item.ref,
            optionId: optionId,
            metadata: metadataFor(item),
          ));
          moviesQueued++;
        } catch (e) {
          debugPrint('Failed to queue download for movie ${item.title}: $e');
          failed++;
        }
      case ItemKind.show:
        try {
          for (final season in await _seasonsOf(source, item.ref)) {
            final result = await queueSourceSeason(
              source: source,
              season: season.ref,
              manager: manager,
              optionId: optionId,
              metadataFor: (episode) => metadataFor(episode).withShow(
                showId: item.ref.externalId,
                showTitle: item.title,
                showPosterUrl: item.poster?.path,
              ),
            );
            episodesQueued += result.queued;
            skipped += result.skipped;
            failed += result.failed;
          }
        } catch (e) {
          debugPrint('Failed to list seasons for ${item.title}: $e');
          failed++;
        }
      default:
        break;
    }
  }

  return CollectionSyncResult(
    moviesQueued: moviesQueued,
    episodesQueued: episodesQueued,
    skipped: skipped,
    failed: failed,
  );
}

/// Every item of [collectionId], following pages until the source says there
/// are no more.
Future<List<ItemSummary>> allCollectionItems(
  MediaSource source,
  String collectionId,
) async {
  final collections =
      source.as<Collections>() ?? (throw const SourceException.unsupported());
  final items = <ItemSummary>[];
  Cursor? cursor;
  do {
    final page =
        await collections.collectionItems(collectionId, cursor: cursor);
    items.addAll(page.items);
    cursor = page.nextCursor;
  } while (cursor != null);
  return items;
}

Future<List<ItemSummary>> _seasonsOf(MediaSource source, ItemRef show) async {
  final seasons = <ItemSummary>[];
  Cursor? cursor;
  do {
    final page = await source.children(show, cursor: cursor);
    seasons.addAll(page.items.where((i) => i.ref.kind == ItemKind.season));
    cursor = page.nextCursor;
  } while (cursor != null);
  return seasons;
}
