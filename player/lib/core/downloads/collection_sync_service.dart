/// Service for syncing collection items for offline download.
///
/// Orchestrates downloading all movies and TV show episodes
/// in a collection, skipping items already downloaded or queued.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/download_request.dart';
import '../../domain/models/movie_detail.dart';
import '../../domain/models/recently_added_item.dart';
import '../../domain/sources/item.dart';
import '../../presentation/screens/movie/movie_detail_controller.dart';
import '../../presentation/screens/show/season_episodes_controller.dart';
import '../../presentation/screens/show/show_detail_controller.dart';
import 'bulk_download_helper.dart';
import 'download_providers.dart';

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
/// Partitions items into movies and shows, fetches full details,
/// and queues bulk downloads for each.
Future<CollectionSyncResult> syncCollectionItems({
  required List<RecentlyAddedItem> items,
  required String resolution,
  required WidgetRef ref,
}) async {
  final downloadManager = await ref.read(downloadManagerProvider.future);

  // Build skip sets
  final downloadedIds = <String>{};
  final queueIds = <String>{};

  final queueAsync = ref.read(downloadQueueProvider);
  if (queueAsync.hasValue) {
    for (final task in queueAsync.value!) {
      queueIds.add(task.mediaId);
    }
  }

  bool Function(String) isDownloadedAs(ItemKind kind) => (id) =>
      downloadedIds.contains(id) ||
      downloadManager.isDownloaded(homeMydiaRef(kind, id));
  final isMovieDownloaded = isDownloadedAs(ItemKind.movie);
  final isEpisodeDownloaded = isDownloadedAs(ItemKind.episode);
  bool isInQueue(String id) => queueIds.contains(id);

  // Partition items
  final movieItems = items.where((i) => i.isMovie).toList();
  final showItems = items.where((i) => i.isShow).toList();

  int moviesQueued = 0;
  int episodesQueued = 0;
  int skipped = 0;
  int failed = 0;

  // Process movies
  if (movieItems.isNotEmpty) {
    final movieDetails = <MovieDetail>[];
    for (final item in movieItems) {
      // Skip if already downloaded/queued (avoid fetching details)
      if (isMovieDownloaded(item.id) || isInQueue(item.id)) {
        skipped++;
        continue;
      }
      try {
        final movie = await ref.read(
          movieDetailControllerProvider(item.id).future,
        );
        if (movie.files.isNotEmpty) {
          movieDetails.add(movie);
        }
      } catch (e) {
        debugPrint('Failed to fetch movie details for ${item.title}: $e');
        failed++;
      }
    }

    if (movieDetails.isNotEmpty) {
      final result = await startBulkMovieDownloads(
        movies: movieDetails,
        resolution: resolution,
        downloadManager: downloadManager,
        isMediaDownloaded: isMovieDownloaded,
        isMediaInQueue: isInQueue,
      );
      moviesQueued += result.queued;
      skipped += result.skipped;
      failed += result.failed;
    }
  }

  // Process shows
  for (final item in showItems) {
    try {
      final show = await ref.read(
        showDetailControllerProvider(item.id).future,
      );

      // Get seasons that have files
      final seasonsWithFiles = show.seasons.where((s) => s.hasFiles).toList();

      for (final season in seasonsWithFiles) {
        try {
          final episodes = await ref.read(
            seasonEpisodesControllerProvider(
              showId: item.id,
              seasonNumber: season.seasonNumber,
            ).future,
          );

          final downloadableEpisodes =
              episodes.where((e) => e.hasFile && e.files.isNotEmpty).toList();

          if (downloadableEpisodes.isNotEmpty) {
            final result = await startBulkEpisodeDownloads(
              episodes: downloadableEpisodes,
              resolution: resolution,
              showId: item.id,
              showTitle: show.title,
              showPosterUrl: show.artwork.posterUrl,
              downloadManager: downloadManager,
              isMediaDownloaded: isEpisodeDownloaded,
              isMediaInQueue: isInQueue,
            );
            episodesQueued += result.queued;
            skipped += result.skipped;
            failed += result.failed;
          }
        } catch (e) {
          debugPrint(
            'Failed to fetch episodes for ${show.title} S${season.seasonNumber}: $e',
          );
          failed++;
        }
      }
    } catch (e) {
      debugPrint('Failed to fetch show details for ${item.title}: $e');
      failed++;
    }
  }

  return CollectionSyncResult(
    moviesQueued: moviesQueued,
    episodesQueued: episodesQueued,
    skipped: skipped,
    failed: failed,
  );
}
