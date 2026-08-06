import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../../core/cache/poster_cache_manager.dart';
import '../../../core/downloads/download_providers.dart';
import '../../../domain/models/download.dart';
import '../../../core/theme/colors.dart';
import '../../widgets/quality_badge.dart';

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
                  Text(
                    'Downloading',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  ...showQueue
                      .map((task) => _buildQueueItem(context, ref, task)),
                  const SizedBox(height: 24),
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
                onTap: () => _showDeleteAllDialog(
                    context, ref, showDownloads, showQueue),
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
        widgets.add(_buildDownloadedItem(context, ref, media));
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
          widgets.add(_buildDownloadedItem(context, ref, media));
        }
      }
    }

    return widgets;
  }

  Widget _buildSeasonHeader(
      BuildContext context, WidgetRef ref, int seasonNumber, int episodeCount) {
    final label = seasonNumber == 0 ? 'Specials' : 'Season $seasonNumber';
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
                onPressed: () => _showDeleteSeasonDialog(
                    context, ref, seasonNumber, episodeCount),
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
  // Queue Item Card (Downloading)
  // ---------------------------------------------------------------------------

  Widget _buildQueueItem(
      BuildContext context, WidgetRef ref, DownloadTask task) {
    final progress = task.isProgressive ? task.combinedProgress : task.progress;
    final episodeCode =
        'S${task.seasonNumber?.toString().padLeft(2, '0') ?? '??'}E${task.episodeNumber?.toString().padLeft(2, '0') ?? '??'}';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.3),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Thumbnail with progress overlay
              SizedBox(
                width: 120,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: task.thumbnailUrl != null
                          ? CachedNetworkImage(
                              imageUrl: task.thumbnailUrl!,
                              fit: BoxFit.cover,
                              cacheManager: EpisodeThumbnailCacheManager(),
                              placeholder: (_, __) =>
                                  _buildThumbnailPlaceholder(),
                              errorWidget: (_, __, ___) =>
                                  _buildThumbnailPlaceholder(),
                            )
                          : _buildThumbnailPlaceholder(),
                    ),
                    // Semi-transparent overlay
                    Positioned.fill(
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.4),
                      ),
                    ),
                    // Progress ring centered
                    Center(
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: CircularProgressIndicator(
                          value: progress,
                          color: AppColors.primary,
                          backgroundColor: Colors.white.withValues(alpha: 0.2),
                          strokeWidth: 3,
                          strokeCap: StrokeCap.round,
                        ),
                      ),
                    ),
                    Center(
                      child: Text(
                        '${(progress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Info area
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Episode code badge + runtime + quality
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
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
                          if (task.runtime != null && task.runtime! > 0)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.access_time_rounded,
                                  size: 14,
                                  color: AppColors.textSecondary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _formatRuntime(task.runtime!),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          if (task.quality.isNotEmpty)
                            QualityBadge.resolution(task.quality),
                        ],
                      ),
                      const SizedBox(height: 6),

                      // Episode title
                      if (task.title.isNotEmpty)
                        Text(
                          task.title,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      const SizedBox(height: 8),

                      // Progress bar
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          backgroundColor: AppColors.surfaceVariant,
                          valueColor: const AlwaysStoppedAnimation<Color>(
                              AppColors.primary),
                        ),
                      ),
                      const SizedBox(height: 6),

                      // Status + bytes
                      Row(
                        children: [
                          Text(
                            task.statusDisplay,
                            style: const TextStyle(
                              color: AppColors.primary,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const Spacer(),
                          Consumer(
                            builder: (context, ref, _) {
                              final speedAsync =
                                  ref.watch(downloadSpeedInfoProvider);
                              return speedAsync.when(
                                data: (speedMap) {
                                  final info = speedMap[task.id];
                                  final parts = <String>[];
                                  final bytesText = task.progressBytesDisplay ??
                                      task.fileSizeDisplay;
                                  parts.add(bytesText);
                                  if (info != null && info.bytesPerSecond > 0) {
                                    parts.add(info.speedDisplay);
                                  }
                                  return Text(
                                    parts.join(' \u00B7 '),
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
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // Cancel button
              Center(
                child: IconButton(
                  onPressed: () => _showCancelDialog(context, ref, task),
                  icon: const Icon(Icons.close_rounded),
                  color: AppColors.textSecondary,
                  iconSize: 20,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Downloaded Item Card
  // ---------------------------------------------------------------------------

  Widget _buildDownloadedItem(
      BuildContext context, WidgetRef ref, DownloadedMedia media) {
    final episodeCode =
        'S${media.seasonNumber?.toString().padLeft(2, '0') ?? '??'}E${media.episodeNumber?.toString().padLeft(2, '0') ?? '??'}';

    return GestureDetector(
      onTap: () {
        context.push(
          '/player/episode/${media.mediaId}?fileId=offline&title=${Uri.encodeComponent(media.title)}&showId=$showId&seasonNumber=${media.seasonNumber}',
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Thumbnail with play button overlay
                SizedBox(
                  width: 120,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: media.thumbnailUrl != null
                            ? CachedNetworkImage(
                                imageUrl: media.thumbnailUrl!,
                                fit: BoxFit.cover,
                                cacheManager: EpisodeThumbnailCacheManager(),
                                placeholder: (_, __) =>
                                    _buildThumbnailPlaceholder(),
                                errorWidget: (_, __, ___) =>
                                    _buildThumbnailPlaceholder(),
                              )
                            : _buildThumbnailPlaceholder(),
                      ),
                      // Play button overlay
                      Center(
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.9),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Info area
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Episode code badge + runtime + quality
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color:
                                    AppColors.primary.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
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
                            if (media.runtime != null && media.runtime! > 0)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.access_time_rounded,
                                    size: 14,
                                    color: AppColors.textSecondary,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _formatRuntime(media.runtime!),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            if (media.quality.isNotEmpty)
                              QualityBadge.resolution(media.quality),
                          ],
                        ),
                        const SizedBox(height: 6),

                        // Episode title
                        Text(
                          media.title,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),

                        // Overview
                        if (media.overview != null &&
                            media.overview!.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            media.overview!,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: AppColors.textSecondary,
                                      height: 1.4,
                                    ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: 6),

                        // File size
                        Text(
                          media.fileSizeDisplay,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Delete button
                Center(
                  child: IconButton(
                    icon: const Icon(Icons.delete_outline_rounded,
                        color: AppColors.error),
                    iconSize: 20,
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: AppColors.surface,
                          title: const Text('Delete Episode'),
                          content: Text('Delete $episodeCode?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.of(context).pop(true),
                              style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.error),
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                      );

                      if (confirm == true) {
                        final manager =
                            await ref.read(downloadManagerProvider.future);
                        await manager.deleteDownload(media.mediaId);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Shared Helpers
  // ---------------------------------------------------------------------------

  Widget _buildThumbnailPlaceholder() {
    return Container(
      color: AppColors.surfaceVariant,
      child: const Center(
        child: Icon(
          Icons.tv_rounded,
          size: 28,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  String _formatRuntime(int minutes) {
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m > 0 ? '${h}h ${m}m' : '${h}h';
  }

  String _totalSizeDisplay(List<DownloadedMedia> downloads) {
    if (downloads.isEmpty) return '0 B';
    final totalBytes = downloads.fold<int>(0, (sum, d) => sum + d.fileSize);
    return DownloadTask.formatBytes(totalBytes);
  }

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------

  Future<void> _showCancelDialog(
      BuildContext context, WidgetRef ref, DownloadTask task) async {
    final manager = await ref.read(downloadManagerProvider.future);

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Cancel Download?'),
        content: const Text('Stop downloading this episode?'),
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

  Future<void> _showDeleteAllDialog(BuildContext context, WidgetRef ref,
      List<DownloadedMedia> showDownloads, List<DownloadTask> showQueue) async {
    final totalCount = showDownloads.length + showQueue.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete All Episodes'),
        content: Text(
          'Delete all $totalCount episode${totalCount == 1 ? '' : 's'} of "$showTitle"?',
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
      await manager.deleteSeriesDownloads(showId);
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _showDeleteSeasonDialog(BuildContext context, WidgetRef ref,
      int seasonNumber, int episodeCount) async {
    final seasonLabel = seasonNumber == 0 ? 'Specials' : 'Season $seasonNumber';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Delete $seasonLabel?'),
        content: Text(
          'Delete $episodeCount episode${episodeCount == 1 ? '' : 's'} from $seasonLabel of "$showTitle"?',
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      final manager = await ref.read(downloadManagerProvider.future);
      await manager.deleteSeasonDownloads(showId, seasonNumber);
    }
  }
}
