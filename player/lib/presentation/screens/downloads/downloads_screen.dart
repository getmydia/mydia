import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../../core/cache/poster_cache_manager.dart';
import '../../../core/layout/dock_insets.dart';
import '../../widgets/ambient_backdrop_provider.dart';
import '../../widgets/cast_actions.dart';
import '../../widgets/cast_button.dart';
import '../../widgets/glass_surface.dart';
import '../../../core/downloads/download_providers.dart';
import '../../../core/downloads/download_queue_providers.dart';
import '../../../core/downloads/storage_quota_providers.dart';
import '../../../domain/models/download.dart';
import '../../../domain/models/download_settings.dart';
import '../../../domain/models/storage_settings.dart';
import '../../../core/theme/colors.dart';
import 'series_downloads_screen.dart';
import 'widgets/download_recovery_banner.dart';

export 'widgets/download_recovery_banner.dart'
    show DownloadRecoveryBanner, downloadStateLabel;

/// The action list shown for an active download in the options sheet.
///
/// Extracted from the sheet so its status logic can be widget-tested without
/// standing up a provider scope or a populated database.
Widget activeDownloadSheetActions({
  required BuildContext context,
  required String status,
  required VoidCallback onPause,
  required VoidCallback onResume,
  required VoidCallback onRestart,
  required VoidCallback onCancel,
}) {
  const resumable = {'paused', 'interrupted', 'stalled'};
  final canResume = resumable.contains(status);

  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (canResume)
        ListTile(
          key: const Key('downloads-sheet-resume'),
          leading:
              const Icon(Icons.play_arrow_rounded, color: AppColors.primary),
          title: const Text('Resume Download'),
          onTap: onResume,
        )
      else
        ListTile(
          key: const Key('downloads-sheet-pause'),
          leading: const Icon(Icons.pause_rounded, color: AppColors.primary),
          title: const Text('Pause Download'),
          onTap: onPause,
        ),
      ListTile(
        key: const Key('downloads-sheet-restart'),
        leading: const Icon(Icons.refresh_rounded, color: AppColors.primary),
        title: const Text('Restart Download'),
        subtitle: const Text('Discards progress and starts over'),
        onTap: onRestart,
      ),
      ListTile(
        key: const Key('downloads-sheet-cancel'),
        leading: const Icon(Icons.cancel_outlined, color: AppColors.error),
        title: const Text('Cancel Download'),
        onTap: onCancel,
      ),
    ],
  );
}

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storageQuotaAsync = ref.watch(storageQuotaStatusProvider);
    final downloadedMediaAsync = ref.watch(downloadedMediaProvider);
    final downloadQueueAsync = ref.watch(downloadQueueProvider);
    final failedDownloadsAsync = ref.watch(failedDownloadsProvider);

    // Downloads uses the calm static backdrop (no per-title artwork).
    publishBackdropSource(ref, BackdropSource.none);

    // Grouping Logic
    final items = <String, DownloadGroup>{};

    // Helper to safely get show ID/Title
    String getGroupKey(bool isEpisode, String? showId, String mediaId) {
      if (isEpisode && showId != null) return showId;
      return mediaId;
    }

    // Process Active Downloads
    if (downloadQueueAsync.hasValue) {
      for (final task in downloadQueueAsync.value!) {
        final isEpisode = task.mediaType == 'episode';
        final key = getGroupKey(isEpisode, task.showId, task.mediaId);

        if (!items.containsKey(key)) {
          items[key] = DownloadGroup(
            id: key,
            title:
                isEpisode ? (task.showTitle ?? 'Unknown Series') : task.title,
            posterUrl: isEpisode ? task.showPosterUrl : task.posterUrl,
            backdropUrl: task.backdropUrl,
            type: isEpisode ? GroupType.series : GroupType.movie,
            updatedAt: task.createdAt,
          );
        }
        items[key]!.activeTasks.add(task);
        if (task.createdAt.isAfter(items[key]!.updatedAt)) {
          items[key]!.updatedAt = task.createdAt;
        }
      }
    }

    // Process Completed Downloads
    if (downloadedMediaAsync.hasValue) {
      for (final media in downloadedMediaAsync.value!) {
        final isEpisode = media.mediaType == 'episode';
        final key = getGroupKey(isEpisode, media.showId, media.mediaId);

        if (!items.containsKey(key)) {
          items[key] = DownloadGroup(
            id: key,
            title:
                isEpisode ? (media.showTitle ?? 'Unknown Series') : media.title,
            posterUrl: isEpisode ? media.showPosterUrl : media.posterUrl,
            backdropUrl: media.backdropUrl,
            type: isEpisode ? GroupType.series : GroupType.movie,
            updatedAt: media.downloadedAt,
          );
        }
        items[key]!.downloads.add(media);
        if (media.downloadedAt.isAfter(items[key]!.updatedAt)) {
          items[key]!.updatedAt = media.downloadedAt;
        }
      }
    }

    final sortedItems = items.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(context, ref),
      body: CustomScrollView(
        slivers: [
          // Top padding for app bar
          const SliverToBoxAdapter(
            child: SizedBox(height: 100),
          ),

          // Storage usage section
          SliverToBoxAdapter(
            child: storageQuotaAsync.when(
              data: (status) => _buildStorageHeader(context, ref, status),
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
          ),

          // Failed downloads section (keep as list for visibility)
          SliverToBoxAdapter(
            child: failedDownloadsAsync.when(
              data: (failed) {
                if (failed.isEmpty) return const SizedBox.shrink();
                return _buildFailedSection(context, ref, failed);
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
          ),

          // Main Grid
          if (sortedItems.isEmpty &&
              !downloadQueueAsync.isLoading &&
              !downloadedMediaAsync.isLoading)
            SliverFillRemaining(
              child: _buildEmptyState(context),
            )
          else
            SliverLayoutBuilder(
              builder: (context, constraints) {
                final crossAxisCount =
                    _calculateCrossAxisCount(constraints.crossAxisExtent);
                return SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      childAspectRatio: 0.48,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 16,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        return _buildGridItem(context, ref, sortedItems[index]);
                      },
                      childCount: sortedItems.length,
                    ),
                  ),
                );
              },
            ),

          const SliverDockGap(),
        ],
      ),
    );
  }

  Widget _buildFailedSection(
      BuildContext context, WidgetRef ref, List<DownloadTask> failed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          child: Row(
            children: [
              const Icon(Icons.error_outline_rounded, color: AppColors.error),
              const SizedBox(width: 8),
              Text(
                'Failed Downloads (${failed.length})',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppColors.error,
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  final manager =
                      await ref.read(downloadManagerProvider.future);
                  await manager.retryAllFailed();
                },
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Retry All', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: const Size(0, 32),
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  final manager =
                      await ref.read(downloadManagerProvider.future);
                  await manager.dismissAllFailed();
                },
                icon: const Icon(Icons.clear_rounded, size: 16),
                label:
                    const Text('Dismiss All', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: const Size(0, 32),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 160,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: failed.length,
            itemBuilder: (context, index) {
              return Container(
                width: 300,
                margin: const EdgeInsets.only(right: 12),
                child: _buildFailedDownloadCard(context, ref, failed[index]),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildGridItem(
      BuildContext context, WidgetRef ref, DownloadGroup group) {
    final isActive = group.activeTasks.isNotEmpty;
    final DownloadTask? activeTask = isActive ? group.activeTasks.first : null;

    double progress = 0.0;
    if (activeTask != null) {
      progress = activeTask.isProgressive
          ? activeTask.combinedProgress
          : activeTask.progress;
    }

    // Build episode code for active series downloads (e.g. "S01E05")
    String? activeEpisodeCode;
    if (activeTask != null && group.type == GroupType.series) {
      final s = activeTask.seasonNumber?.toString().padLeft(2, '0') ?? '??';
      final e = activeTask.episodeNumber?.toString().padLeft(2, '0') ?? '??';
      activeEpisodeCode = 'S${s}E$e';
    }

    return GestureDetector(
      onTap: () async {
        if (group.type == GroupType.series) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => SeriesDownloadsScreen(
                showId: group.id,
                showTitle: group.title,
                showPosterUrl: group.posterUrl,
                backdropUrl: group.backdropUrl,
              ),
            ),
          );
        } else {
          if (activeTask != null) {
            _showCancelDialog(context, ref, activeTask);
          } else if (group.downloads.isNotEmpty) {
            final media = group.downloads.first;
            context.push(
              '/player/movie/${media.mediaId}?fileId=offline&title=${Uri.encodeComponent(media.title)}',
            );
          }
        }
      },
      onLongPress: () => _showItemOptions(context, ref, group),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Poster area
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Poster image
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: group.posterUrl != null
                      ? CachedNetworkImage(
                          imageUrl: group.posterUrl!,
                          fit: BoxFit.cover,
                          cacheManager: PosterCacheManager(),
                          placeholder: (_, __) =>
                              Container(color: AppColors.surfaceVariant),
                          errorWidget: (_, __, ___) => Container(
                            color: AppColors.surfaceVariant,
                            child: const Icon(Icons.movie,
                                color: AppColors.textSecondary),
                          ),
                        )
                      : Container(
                          color: AppColors.surfaceVariant,
                          child: const Icon(Icons.movie,
                              color: AppColors.textSecondary),
                        ),
                ),

                // Active overlay + progress ring
                if (isActive) ...[
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  Center(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(
                            value: progress,
                            color: AppColors.primary,
                            backgroundColor:
                                Colors.white.withValues(alpha: 0.15),
                            strokeWidth: 4,
                            strokeCap: StrokeCap.round,
                          ),
                        ),
                        Text(
                          '${(progress * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Episode code strip on poster for active series downloads
                if (isActive && activeEpisodeCode != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(12),
                        bottomRight: Radius.circular(12),
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.85),
                            ],
                          ),
                        ),
                        child: Text(
                          activeEpisodeCode,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ),

                // Series episode count badge (always visible)
                if (group.type == GroupType.series)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.video_library_rounded,
                            color: Colors.white,
                            size: 10,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '${group.downloads.length + group.activeTasks.length}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Info area below poster
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title
                Text(
                  group.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),

                // Episode title for active series downloads
                if (activeTask != null && group.type == GroupType.series)
                  Text(
                    activeTask.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 10,
                    ),
                  ),

                if (activeTask != null &&
                    downloadStateLabel(activeTask).isNotEmpty)
                  Builder(
                    builder: (context) {
                      final task = activeTask;
                      return Consumer(
                        builder: (context, ref, _) => DownloadRecoveryBanner(
                          task: task,
                          onResume: () async {
                            final manager =
                                await ref.read(downloadManagerProvider.future);
                            await manager.resumeDownload(task.id);
                          },
                        ),
                      );
                    },
                  ),

                // Download stats (only when active and not recovering)
                if (isActive &&
                    activeTask != null &&
                    downloadStateLabel(activeTask).isEmpty)
                  Builder(
                    builder: (context) {
                      final task = activeTask;
                      final bytesText =
                          task.progressBytesDisplay ?? task.fileSizeDisplay;

                      return Consumer(
                        builder: (context, ref, _) {
                          final speedAsync =
                              ref.watch(downloadSpeedInfoProvider);
                          String? speedText;
                          speedAsync.when(
                            data: (speedMap) {
                              final info = speedMap[task.id];
                              if (info != null && info.bytesPerSecond > 0) {
                                speedText = info.speedDisplay;
                              }
                            },
                            loading: () {},
                            error: (_, __) {},
                          );

                          final parts = <String>[bytesText];
                          final speed = speedText;
                          if (speed != null) parts.add(speed);

                          return Text(
                            parts.join(' \u00B7 '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 10,
                            ),
                          );
                        },
                      );
                    },
                  ),

                // File size for completed downloads
                if (!isActive && group.downloads.isNotEmpty)
                  Text(
                    group.type == GroupType.series
                        ? '${group.downloads.length} episode${group.downloads.length == 1 ? '' : 's'}'
                        : group.downloads.first.fileSizeDisplay,
                    maxLines: 1,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showCancelDialog(
      BuildContext context, WidgetRef ref, DownloadTask task) async {
    final manager = await ref.read(downloadManagerProvider.future);

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Cancel Download?'),
        content: Text('Stop downloading "${task.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Keep',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          FilledButton(
            onPressed: () {
              manager.cancelDownload(task.id);
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Cancel Download'),
          ),
        ],
      ),
    );
  }

  void _showItemOptions(
      BuildContext context, WidgetRef ref, DownloadGroup group) {
    final isActive = group.activeTasks.isNotEmpty;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.textSecondary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Title
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Text(
                  group.title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 8),

              if (isActive) ...[
                Builder(builder: (_) {
                  final task = group.activeTasks.first;
                  return activeDownloadSheetActions(
                    context: context,
                    status: task.status,
                    onPause: () async {
                      Navigator.pop(sheetContext);
                      final manager =
                          await ref.read(downloadManagerProvider.future);
                      await manager.pauseDownload(task.id);
                    },
                    onResume: () async {
                      Navigator.pop(sheetContext);
                      final manager =
                          await ref.read(downloadManagerProvider.future);
                      await manager.resumeDownload(task.id);
                    },
                    onRestart: () async {
                      Navigator.pop(sheetContext);
                      final manager =
                          await ref.read(downloadManagerProvider.future);
                      await manager.restartDownload(task.id);
                    },
                    onCancel: () {
                      Navigator.pop(sheetContext);
                      _showCancelDialog(context, ref, task);
                    },
                  );
                }),
              ] else if (group.type == GroupType.movie) ...[
                // Completed movie: play + delete
                ListTile(
                  leading: const Icon(Icons.play_arrow_rounded,
                      color: AppColors.primary),
                  title: const Text('Play'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (group.downloads.isNotEmpty) {
                      final media = group.downloads.first;
                      context.push(
                        '/player/movie/${media.mediaId}?fileId=offline&title=${Uri.encodeComponent(media.title)}',
                      );
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded,
                      color: AppColors.error),
                  title: const Text('Delete',
                      style: TextStyle(color: AppColors.error)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showDeleteMovieDialog(context, ref, group);
                  },
                ),
              ] else if (group.type == GroupType.series) ...[
                // Completed series: view episodes + delete all
                ListTile(
                  leading:
                      const Icon(Icons.list_rounded, color: AppColors.primary),
                  title: const Text('View Episodes'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => SeriesDownloadsScreen(
                          showId: group.id,
                          showTitle: group.title,
                          showPosterUrl: group.posterUrl,
                          backdropUrl: group.backdropUrl,
                        ),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded,
                      color: AppColors.error),
                  title: const Text('Delete All Episodes',
                      style: TextStyle(color: AppColors.error)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showDeleteSeriesDialog(context, ref, group);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showDeleteMovieDialog(
      BuildContext context, WidgetRef ref, DownloadGroup group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete Download'),
        content: Text(
            'Delete "${group.title}"? The downloaded file will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      final manager = await ref.read(downloadManagerProvider.future);
      for (final media in group.downloads) {
        await manager.deleteDownload(media.mediaId);
      }
    }
  }

  Future<void> _showDeleteSeriesDialog(
      BuildContext context, WidgetRef ref, DownloadGroup group) async {
    final episodeCount = group.downloads.length + group.activeTasks.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete All Episodes'),
        content: Text(
          'Delete all $episodeCount episode${episodeCount == 1 ? '' : 's'} of "${group.title}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      final manager = await ref.read(downloadManagerProvider.future);
      await manager.deleteSeriesDownloads(group.id);
    }
  }

  Future<void> _showCancelAllQueuedDialog(
      BuildContext context, WidgetRef ref, int queuedCount) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Cancel All Queued?'),
        content: Text(
          'Cancel $queuedCount queued download${queuedCount == 1 ? '' : 's'}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Cancel All'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      final manager = await ref.read(downloadManagerProvider.future);
      await manager.cancelAllQueued();
    }
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, WidgetRef ref) {
    final queueAsync = ref.watch(downloadQueueProvider);
    final queuedCount = queueAsync.whenOrNull(
          data: (tasks) => tasks
              .where((t) => t.status == 'queued' || t.status == 'pending')
              .length,
        ) ??
        0;

    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: GlassSurface.appBar(
        opacity: 0.85,
        child: SafeArea(
          child: SizedBox(
            height: kToolbarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(
                    Icons.download_rounded,
                    color: AppColors.primary,
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Downloads',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.3,
                        ),
                  ),
                  const Spacer(),
                  if (queuedCount > 0) ...[
                    IconButton(
                      onPressed: () =>
                          _showCancelAllQueuedDialog(context, ref, queuedCount),
                      tooltip: 'Cancel all queued',
                      icon: const Icon(
                        Icons.clear_all_rounded,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  // DownloadsScreen's app bar is always visible (no
                  // desktop suppression), so it carries its own cast
                  // affordance instead of the shell's overlay — see
                  // AppShell._hasOwnCastButton.
                  CastButton(
                    onPressed: () => pickCastDevice(context, ref),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStorageHeader(
      BuildContext context, WidgetRef ref, StorageQuotaStatus status) {
    // Determine colors based on status
    final isWarning = status.isWarningExceeded;
    final isFull = status.isFull;
    final iconColor = isFull
        ? AppColors.error
        : (isWarning ? AppColors.warning : AppColors.primary);
    final progressColor = isFull
        ? AppColors.error
        : (isWarning ? AppColors.warning : AppColors.primary);

    final hasActiveDownloads =
        status.inProgressBytes > 0 || status.queuedBytes > 0;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.surface,
            AppColors.surfaceVariant.withValues(alpha: 0.5),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isWarning
              ? iconColor.withValues(alpha: 0.5)
              : AppColors.divider.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  isFull
                      ? Icons.storage_rounded
                      : (isWarning
                          ? Icons.warning_amber_rounded
                          : Icons.storage_rounded),
                  color: iconColor,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Storage Used',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppColors.textSecondary,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      status.settings.hasLimit
                          ? '${status.usedDisplay} / ${status.maxDisplay}'
                          : status.usedDisplay,
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                    ),
                  ],
                ),
              ),
              // Settings button
              Material(
                color: AppColors.surfaceVariant.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _showStorageSettings(context, ref, status),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(
                      Icons.settings_rounded,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          // Segmented progress bar if limit is set
          if (status.settings.hasLimit) ...[
            const SizedBox(height: 16),
            _buildSegmentedProgressBar(
              status: status,
              completedColor: progressColor,
            ),
          ],
          // Breakdown of in-progress and queued downloads
          if (hasActiveDownloads) ...[
            const SizedBox(height: 12),
            _buildStorageBreakdown(context, status, progressColor),
          ],
        ],
      ),
    );
  }

  Widget _buildSegmentedProgressBar({
    required StorageQuotaStatus status,
    required Color completedColor,
  }) {
    final maxBytes = status.maxBytes ?? 1;
    final completedFrac = (status.usedBytes / maxBytes).clamp(0.0, 1.0);
    final inProgressFrac =
        (status.inProgressBytes / maxBytes).clamp(0.0, 1.0 - completedFrac);
    final queuedFrac = (status.queuedBytes / maxBytes)
        .clamp(0.0, 1.0 - completedFrac - inProgressFrac);
    final remainingFrac =
        (1.0 - completedFrac - inProgressFrac - queuedFrac).clamp(0.0, 1.0);

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            if (completedFrac > 0)
              Flexible(
                flex: (completedFrac * 1000).round(),
                child: Container(color: completedColor),
              ),
            if (inProgressFrac > 0)
              Flexible(
                flex: (inProgressFrac * 1000).round(),
                child: Container(
                  color: completedColor.withValues(alpha: 0.45),
                ),
              ),
            if (queuedFrac > 0)
              Flexible(
                flex: (queuedFrac * 1000).round(),
                child: Container(
                  color: completedColor.withValues(alpha: 0.2),
                ),
              ),
            if (remainingFrac > 0)
              Flexible(
                flex: (remainingFrac * 1000).round(),
                child: Container(color: AppColors.surfaceVariant),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStorageBreakdown(
      BuildContext context, StorageQuotaStatus status, Color baseColor) {
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        if (status.inProgressBytes > 0)
          _buildBreakdownChip(
            context,
            color: baseColor.withValues(alpha: 0.45),
            label: '${status.inProgressDisplay} downloading',
          ),
        if (status.queuedBytes > 0)
          _buildBreakdownChip(
            context,
            color: baseColor.withValues(alpha: 0.2),
            label: '${status.queuedDisplay} queued',
          ),
      ],
    );
  }

  Widget _buildBreakdownChip(
    BuildContext context, {
    required Color color,
    required String label,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.textSecondary,
                fontSize: 11,
              ),
        ),
      ],
    );
  }

  void _showStorageSettings(
      BuildContext context, WidgetRef ref, StorageQuotaStatus status) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _StorageSettingsSheet(
        currentSettings: status.settings,
        currentUsage: status.usedBytes,
      ),
    );
  }

  int _calculateCrossAxisCount(double width) {
    if (width > 1400) return 8;
    if (width > 1200) return 7;
    if (width > 1000) return 6;
    if (width > 800) return 5;
    if (width > 600) return 4;
    if (width > 400) return 3;
    return 2;
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.cloud_download_rounded,
                size: 56,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No downloads yet',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Download movies and shows to watch offline',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFailedDownloadCard(
    BuildContext context,
    WidgetRef ref,
    DownloadTask task,
  ) {
    final posterUrl = task.mediaType == 'episode'
        ? (task.showPosterUrl ?? task.posterUrl)
        : task.posterUrl;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.error.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          // Poster
          SizedBox(
            width: 90,
            height: 160,
            child: posterUrl != null
                ? CachedNetworkImage(
                    imageUrl: posterUrl,
                    fit: BoxFit.cover,
                    cacheManager: PosterCacheManager(),
                    placeholder: (_, __) =>
                        Container(color: AppColors.surfaceVariant),
                    errorWidget: (_, __, ___) => Container(
                      color: AppColors.surfaceVariant,
                      child: const Icon(Icons.movie,
                          color: AppColors.textSecondary),
                    ),
                  )
                : Container(
                    color: AppColors.surfaceVariant,
                    child:
                        const Icon(Icons.movie, color: AppColors.textSecondary),
                  ),
          ),
          // Info
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.error_outline_rounded,
                          color: AppColors.error, size: 14),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          task.error ?? 'Download failed',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TextStyle(color: AppColors.error, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () async {
                          final manager =
                              await ref.read(downloadManagerProvider.future);
                          await manager.cancelDownload(task.id);
                        },
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 32),
                        ),
                        child: const Text('Dismiss',
                            style: TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 4),
                      FilledButton(
                        onPressed: () async {
                          final manager =
                              await ref.read(downloadManagerProvider.future);
                          await manager.retryDownload(task.id);
                        },
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 0),
                          backgroundColor: AppColors.primary,
                          minimumSize: const Size(0, 32),
                        ),
                        child:
                            const Text('Retry', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Storage settings bottom sheet.
class _StorageSettingsSheet extends ConsumerStatefulWidget {
  final StorageSettings currentSettings;
  final int currentUsage;

  const _StorageSettingsSheet({
    required this.currentSettings,
    required this.currentUsage,
  });

  @override
  ConsumerState<_StorageSettingsSheet> createState() =>
      _StorageSettingsSheetState();
}

class _StorageSettingsSheetState extends ConsumerState<_StorageSettingsSheet> {
  late int? _selectedLimit;
  late double _warningThreshold;
  late bool _autoCleanupEnabled;
  late CleanupPolicy _cleanupPolicy;
  late int _maxConcurrentDownloads;
  late bool _autoStartQueued;

  static const List<int?> _limitOptions = [
    null, // No limit
    StorageSettings.gb1,
    StorageSettings.gb2,
    StorageSettings.gb5,
    StorageSettings.gb10,
    StorageSettings.gb20,
  ];

  static const List<int> _concurrentOptions = [1, 2, 3, 4, 5];

  @override
  void initState() {
    super.initState();
    _selectedLimit = widget.currentSettings.maxStorageBytes;
    _warningThreshold = widget.currentSettings.warningThreshold;
    _autoCleanupEnabled = widget.currentSettings.autoCleanupEnabled;
    _cleanupPolicy = widget.currentSettings.cleanupPolicy;
    _maxConcurrentDownloads = 2; // Default, will be loaded async
    _autoStartQueued = true;
    _loadDownloadSettings();
  }

  Future<void> _loadDownloadSettings() async {
    final downloadSettings = await ref.read(downloadSettingsProvider.future);
    if (mounted) {
      setState(() {
        _maxConcurrentDownloads = downloadSettings.maxConcurrentDownloads;
        _autoStartQueued = downloadSettings.autoStartQueued;
      });
    }
  }

  String _formatLimit(int? limit) {
    if (limit == null) return 'No limit';
    return StorageSettings.formatBytes(limit);
  }

  Future<void> _saveSettings() async {
    // Save storage settings
    final updateStorageSettings = ref.read(updateStorageSettingsProvider);
    final newStorageSettings = StorageSettings(
      maxStorageBytes: _selectedLimit,
      warningThreshold: _warningThreshold,
      autoCleanupEnabled: _autoCleanupEnabled,
      cleanupPolicyValue: _cleanupPolicy.name,
    );
    await updateStorageSettings(newStorageSettings);

    // Save download settings
    final updateDownloadSettings = ref.read(updateDownloadSettingsProvider);
    final newDownloadSettings = DownloadSettings(
      maxConcurrentDownloads: _maxConcurrentDownloads,
      autoStartQueued: _autoStartQueued,
    );
    await updateDownloadSettings(newDownloadSettings);

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _cleanupNow() async {
    final cleanupService = await ref.read(storageCleanupServiceProvider.future);
    final totalCleanable = cleanupService.getTotalCleanableBytes();

    if (totalCleanable == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No downloads to clean up')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Clean Up Downloads'),
        content: Text(
          'This will delete all downloaded media (${StorageSettings.formatBytes(totalCleanable)}). '
          'Are you sure?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final freedBytes = await cleanupService.cleanup(
        targetBytes: totalCleanable,
        policy: _cleanupPolicy,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('Freed ${StorageSettings.formatBytes(freedBytes)}')),
        );
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.settings_rounded,
                    color: AppColors.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                'Storage Settings',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Storage limit dropdown
          Text(
            'Maximum Storage',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int?>(
                isExpanded: true,
                value: _limitOptions.contains(_selectedLimit)
                    ? _selectedLimit
                    : null,
                items: _limitOptions.map((limit) {
                  final isCurrentlyUsed =
                      limit != null && widget.currentUsage > limit;
                  return DropdownMenuItem(
                    value: limit,
                    child: Row(
                      children: [
                        Text(_formatLimit(limit)),
                        if (isCurrentlyUsed) ...[
                          const SizedBox(width: 8),
                          Text(
                            '(Full)',
                            style: TextStyle(
                              color: AppColors.error,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (value) => setState(() => _selectedLimit = value),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Concurrent downloads
          Text(
            'Concurrent Downloads',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                isExpanded: true,
                value: _maxConcurrentDownloads,
                items: _concurrentOptions.map((count) {
                  return DropdownMenuItem(
                    value: count,
                    child: Text('$count'),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _maxConcurrentDownloads = value);
                  }
                },
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Auto start switch
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Auto Start Downloads',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              Switch(
                value: _autoStartQueued,
                onChanged: (value) => setState(() => _autoStartQueued = value),
                activeColor: AppColors.primary,
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Auto cleanup switch
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Auto Cleanup',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              Switch(
                value: _autoCleanupEnabled,
                onChanged: (value) =>
                    setState(() => _autoCleanupEnabled = value),
                activeColor: AppColors.primary,
              ),
            ],
          ),

          if (_autoCleanupEnabled) ...[
            const SizedBox(height: 16),
            Text(
              'Cleanup Policy',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<CleanupPolicy>(
                  isExpanded: true,
                  value: _cleanupPolicy,
                  items: CleanupPolicy.values.map((policy) {
                    return DropdownMenuItem(
                      value: policy,
                      child: Text(policy.display),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _cleanupPolicy = value);
                  },
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),

          // Actions
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _cleanupNow,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    side: BorderSide(color: AppColors.error),
                    foregroundColor: AppColors.error,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Clean Up Now'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _saveSettings,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Group Types
enum GroupType { movie, series }

// Helper class for grouping downloads
class DownloadGroup {
  final String id;
  final String title;
  final String? posterUrl;
  final String? backdropUrl;
  final GroupType type;
  DateTime updatedAt;
  final List<DownloadTask> activeTasks = [];
  final List<DownloadedMedia> downloads = [];

  DownloadGroup({
    required this.id,
    required this.title,
    this.posterUrl,
    this.backdropUrl,
    required this.type,
    required this.updatedAt,
  });
}
