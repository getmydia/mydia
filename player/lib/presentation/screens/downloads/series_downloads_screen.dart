import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../../core/cache/poster_cache_manager.dart';
import '../../../core/downloads/download_providers.dart';
import '../../../domain/models/download.dart';
import '../../../core/theme/colors.dart';
import '../../widgets/quality_badge.dart';
import 'widgets/series_downloads_dialogs.dart';

class SeriesDownloadsScreen extends ConsumerWidget {
  final String showId;
  final String showTitle;
  final String? showPosterUrl;
  final String? backdropUrl;

  const SeriesDownloadsScreen({
    super.key,
    required this.showId,
    required this.showTitle,
    this.showPosterUrl,
    this.backdropUrl,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadedMediaAsync = ref.watch(downloadedMediaProvider);
    final downloadQueueAsync = ref.watch(downloadQueueProvider);

    // Combine data
    final downloaded = downloadedMediaAsync.value ?? [];
    final queue = downloadQueueAsync.value ?? [];

    // Filter for this show
    final showDownloads = downloaded
        .where((m) =>
            m.showId == showId || (m.showId == null && m.mediaId == showId))
        .toList();
    final showQueue = queue
        .where((t) =>
            t.showId == showId || (t.showId == null && t.mediaId == showId))
        .toList();

    // Sort by Season/Episode
    showDownloads.sort((a, b) {
      final sA = a.seasonNumber ?? 0;
      final sB = b.seasonNumber ?? 0;
      if (sA != sB) return sA.compareTo(sB);
      return (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
    });

    showQueue.sort((a, b) {
      final sA = a.seasonNumber ?? 0;
      final sB = b.seasonNumber ?? 0;
      if (sA != sB) return sA.compareTo(sB);
      return (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          _buildHeroSection(context, ref, showDownloads, showQueue),
          _buildStatsBar(context, showDownloads, showQueue),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                if (showQueue.isNotEmpty) ...[
                  ..._buildQueueSection(context, ref, showQueue),
                  if (showDownloads.isNotEmpty) const SizedBox(height: 24),
                ],
                if (showDownloads.isNotEmpty)
                  ..._buildDownloadedSection(context, ref, showDownloads),
                if (showQueue.isEmpty && showDownloads.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text("No episodes found")),
                  ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Hero Section
  // ---------------------------------------------------------------------------

  Widget _buildHeroSection(BuildContext context, WidgetRef ref,
      List<DownloadedMedia> showDownloads, List<DownloadTask> showQueue) {
    return SliverAppBar(
      expandedHeight: 280,
      pinned: true,
      stretch: true,
      backgroundColor: AppColors.background,
      actions: [
        if (showDownloads.isNotEmpty || showQueue.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Material(
              color: Colors.black.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () async {
                  final deleted = await showDeleteAllDialog(
                    context,
                    ref,
                    showId: showId,
                    showTitle: showTitle,
                    totalCount: showDownloads.length + showQueue.length,
                  );
                  if (deleted && context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.delete_outline_rounded,
                      color: AppColors.error),
                ),
              ),
            ),
          ),
        const SizedBox(width: 8),
      ],
      leading: Padding(
        padding: const EdgeInsets.all(8),
        child: Material(
          color: Colors.black.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/');
              }
            },
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.arrow_back_rounded, color: Colors.white),
            ),
          ),
        ),
      ),
      flexibleSpace: FlexibleSpaceBar(
        stretchModes: const [
          StretchMode.zoomBackground,
          StretchMode.blurBackground,
        ],
        background: Stack(
          fit: StackFit.expand,
          children: [
            // Backdrop image
            if (backdropUrl != null)
              CachedNetworkImage(
                imageUrl: backdropUrl!,
                fit: BoxFit.cover,
                cacheManager: BackdropCacheManager(),
                placeholder: (context, url) =>
                    Container(color: AppColors.surface),
                errorWidget: (context, url, error) =>
                    Container(color: AppColors.surface),
              )
            else
              Container(color: AppColors.surface),

            // Multi-stop gradient overlay
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    AppColors.background.withValues(alpha: 0.5),
                    AppColors.background.withValues(alpha: 0.95),
                    AppColors.background,
                  ],
                  stops: const [0.0, 0.5, 0.8, 1.0],
                ),
              ),
            ),

            // Content overlay: poster + title + summary stats
            Positioned(
              left: 20,
              right: 20,
              bottom: 20,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Poster
                  _buildPoster(),
                  const SizedBox(width: 16),
                  // Title and stats
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          showTitle,
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                            fontWeight: FontWeight.bold,
                            shadows: [
                              Shadow(
                                color: Colors.black.withValues(alpha: 0.8),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        _buildHeroStats(context, showDownloads, showQueue),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPoster() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 100,
          height: 150,
          child: showPosterUrl != null
              ? CachedNetworkImage(
                  imageUrl: showPosterUrl!,
                  fit: BoxFit.cover,
                  cacheManager: PosterCacheManager(),
                  placeholder: (context, url) => Container(
                    color: AppColors.surfaceVariant,
                  ),
                  errorWidget: (context, url, error) => Container(
                    color: AppColors.surfaceVariant,
                    child: const Icon(Icons.tv_rounded,
                        color: AppColors.textSecondary),
                  ),
                )
              : Container(
                  color: AppColors.surfaceVariant,
                  child: const Icon(Icons.tv_rounded,
                      color: AppColors.textSecondary),
                ),
        ),
      ),
    );
  }

  Widget _buildHeroStats(BuildContext context, List<DownloadedMedia> downloads,
      List<DownloadTask> queue) {
    final totalEpisodes = downloads.length + queue.length;
    final seasons = <int>{
      ...downloads.map((d) => d.seasonNumber ?? 0),
      ...queue.map((t) => t.seasonNumber ?? 0),
    };

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _buildStatBadge(
          Icons.movie_rounded,
          '$totalEpisodes Ep${totalEpisodes != 1 ? 's' : ''}',
        ),
        if (seasons.length > 1)
          _buildStatBadge(
            Icons.folder_rounded,
            '${seasons.length} Seasons',
          ),
        _buildStatBadge(
          Icons.storage_rounded,
          _totalSizeDisplay(downloads),
        ),
      ],
    );
  }

  Widget _buildStatBadge(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.textSecondary),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Stats Bar
  // ---------------------------------------------------------------------------

  Widget _buildStatsBar(BuildContext context, List<DownloadedMedia> downloads,
      List<DownloadTask> queue) {
    final allQualities = <String>{
      ...downloads.map((d) => d.quality),
      ...queue.map((t) => t.quality),
    }.where((q) => q.isNotEmpty).toList();

    if (allQualities.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox(height: 8));
    }

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children:
              allQualities.map((q) => QualityBadge.resolution(q)).toList(),
        ),
      ),
    );
  }

  /// Shared compact row for queue and downloaded episode items.
  Widget _buildEpisodeRow({
    required BuildContext context,
    required String episodeCode,
    required String title,
    required Widget trailing,
    VoidCallback? onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              children: [
                // Episode code badge
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    episodeCode,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Title
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                // Trailing section (metrics + actions)
                trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDownloadedRow(
      BuildContext context, WidgetRef ref, DownloadedMedia media) {
    final episodeCode = media.episodeCode;

    final trailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (media.quality.isNotEmpty) ...[
          QualityBadge.resolution(media.quality),
          const SizedBox(width: 8),
        ],
        Text(
          media.fileSizeDisplay,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 11,
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.play_arrow_rounded, color: AppColors.primary),
          iconSize: 22,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: () {
            context.push(
              '/player/episode/${media.mediaId}?fileId=offline&title=${Uri.encodeComponent(media.title)}&showId=$showId&seasonNumber=${media.seasonNumber}',
            );
          },
        ),
        IconButton(
          icon:
              const Icon(Icons.delete_outline_rounded, color: AppColors.error),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: () => showDeleteEpisodeDialog(context, ref, media),
        ),
      ],
    );

    return _buildEpisodeRow(
      context: context,
      episodeCode: episodeCode,
      title: media.title,
      trailing: trailing,
      onTap: () {
        context.push(
          '/player/episode/${media.mediaId}?fileId=offline&title=${Uri.encodeComponent(media.title)}&showId=$showId&seasonNumber=${media.seasonNumber}',
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Downloaded Section with Season Grouping
  // ---------------------------------------------------------------------------

  List<Widget> _buildDownloadedSection(
      BuildContext context, WidgetRef ref, List<DownloadedMedia> downloads) {
    final widgets = <Widget>[];

    final seasonMap = _groupBySeason(downloads, (d) => d.seasonNumber ?? 0);
    final hasMultipleSeasons = seasonMap.length > 1;

    if (!hasMultipleSeasons) {
      widgets.add(Text(
        'Downloaded',
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: AppColors.success,
              fontWeight: FontWeight.bold,
            ),
      ));
      widgets.add(const SizedBox(height: 8));
      for (final media in downloads) {
        widgets.add(_buildDownloadedRow(context, ref, media));
      }
    } else {
      widgets.add(Text(
        'Downloaded',
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: AppColors.success,
              fontWeight: FontWeight.bold,
            ),
      ));
      widgets.add(const SizedBox(height: 12));

      var first = true;
      for (final entry in seasonMap.entries) {
        final season = entry.key;
        final seasonEpisodes = entry.value;
        if (!first) widgets.add(const SizedBox(height: 16));
        first = false;
        widgets.add(
            _buildSeasonHeader(context, ref, season, seasonEpisodes.length));
        widgets.add(const SizedBox(height: 8));
        for (final media in seasonEpisodes) {
          widgets.add(_buildDownloadedRow(context, ref, media));
        }
      }
    }

    return widgets;
  }

  Widget _buildSeasonHeader(
      BuildContext context, WidgetRef ref, int seasonNumber, int episodeCount) {
    final label = seasonLabel(seasonNumber);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        padding: const EdgeInsets.only(bottom: 8),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: AppColors.divider,
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                  ),
            ),
            const SizedBox(width: 8),
            Text(
              '($episodeCount episode${episodeCount != 1 ? 's' : ''})',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary.withValues(alpha: 0.7),
                  ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                height: 1,
                color: AppColors.divider.withValues(alpha: 0.3),
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                onPressed: () => showDeleteSeasonDialog(
                  context,
                  ref,
                  showId: showId,
                  showTitle: showTitle,
                  seasonNumber: seasonNumber,
                  episodeCount: episodeCount,
                ),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                color: AppColors.error,
                padding: EdgeInsets.zero,
                tooltip: 'Delete $label',
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Queue Section with Season Grouping
  // ---------------------------------------------------------------------------

  List<Widget> _buildQueueSection(
      BuildContext context, WidgetRef ref, List<DownloadTask> queue) {
    final widgets = <Widget>[];

    widgets.add(Text(
      'Downloading',
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: AppColors.primary,
            fontWeight: FontWeight.bold,
          ),
    ));

    final seasonMap = _groupBySeason(queue, (t) => t.seasonNumber ?? 0);
    final hasMultipleSeasons = seasonMap.length > 1;

    if (!hasMultipleSeasons) {
      widgets.add(const SizedBox(height: 8));
      for (final task in queue) {
        widgets.add(_buildQueueRow(context, ref, task));
      }
    } else {
      widgets.add(const SizedBox(height: 12));
      var first = true;
      for (final entry in seasonMap.entries) {
        final season = entry.key;
        final seasonTasks = entry.value;
        if (!first) widgets.add(const SizedBox(height: 16));
        first = false;
        widgets
            .add(_buildQueueSeasonHeader(context, season, seasonTasks.length));
        widgets.add(const SizedBox(height: 8));
        for (final task in seasonTasks) {
          widgets.add(_buildQueueRow(context, ref, task));
        }
      }
    }

    return widgets;
  }

  Widget _buildQueueRow(
      BuildContext context, WidgetRef ref, DownloadTask task) {
    final progress = task.isProgressive ? task.combinedProgress : task.progress;
    final episodeCode =
        'S${task.seasonNumber?.toString().padLeft(2, '0') ?? '??'}E${task.episodeNumber?.toString().padLeft(2, '0') ?? '??'}';

    final trailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Consumer(
          builder: (context, ref, _) {
            final speedAsync = ref.watch(downloadSpeedInfoProvider);
            return speedAsync.when(
              data: (speedMap) {
                final info = speedMap[task.id];
                final parts = <String>[];
                final bytesText =
                    task.progressBytesDisplay ?? task.fileSizeDisplay;
                parts.add(bytesText);
                if (info != null && info.bytesPerSecond > 0) {
                  parts.add(info.speedDisplay);
                }
                return Text(
                  parts.join(' \u00B7 '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 10,
                  ),
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            );
          },
        ),
        const SizedBox(width: 6),
        Text(
          '${(progress * 100).toStringAsFixed(0)}%',
          style: const TextStyle(
            color: AppColors.primary,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          onPressed: () => showCancelDownloadDialog(context, ref, task),
          icon: const Icon(Icons.close_rounded),
          color: AppColors.textSecondary,
          iconSize: 18,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ],
    );

    return _buildEpisodeRow(
      context: context,
      episodeCode: episodeCode,
      title: task.title,
      trailing: trailing,
    );
  }

  Widget _buildQueueSeasonHeader(
      BuildContext context, int seasonNumber, int taskCount) {
    final label = seasonLabel(seasonNumber);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        padding: const EdgeInsets.only(bottom: 8),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: AppColors.divider,
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                  ),
            ),
            const SizedBox(width: 8),
            Text(
              '($taskCount downloading)',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary.withValues(alpha: 0.7),
                  ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                height: 1,
                color: AppColors.divider.withValues(alpha: 0.3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _totalSizeDisplay(List<DownloadedMedia> downloads) {
    if (downloads.isEmpty) return '0 B';
    final totalBytes = downloads.fold<int>(0, (sum, d) => sum + d.fileSize);
    return DownloadTask.formatBytes(totalBytes);
  }

  /// Groups items by season number, returning a sorted map (Specials=0 first,
  /// then ascending).
  Map<int, List<T>> _groupBySeason<T>(List<T> items, int Function(T) seasonOf) {
    final map = <int, List<T>>{};
    for (final item in items) {
      final season = seasonOf(item);
      map.putIfAbsent(season, () => []).add(item);
    }
    final sorted = Map.fromEntries(
      map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return sorted;
  }
}
