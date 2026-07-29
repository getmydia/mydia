import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/cache/poster_cache_manager.dart';
import '../../../core/downloads/bulk_download_helper.dart';
import '../../../core/downloads/download_job_providers.dart';
import '../../../core/downloads/download_providers.dart';
import '../../../core/downloads/download_service.dart';
import 'show_detail_controller.dart';
import 'season_episodes_controller.dart';
import '../../../domain/models/show_detail.dart';
import '../../../domain/models/season_info.dart';
import '../../../domain/models/episode.dart';
import '../../widgets/episode_card.dart';
import '../../widgets/freshness_header.dart';
import '../../widgets/quality_download_dialog.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/player/media_file_selector.dart';
import '../../../core/theme/colors.dart';
import '../../widgets/smart_play_button.dart';

class ShowDetailScreen extends ConsumerWidget {
  final String id;

  const ShowDetailScreen({
    super.key,
    required this.id,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showAsync = ref.watch(showDetailControllerProvider(id));
    final selectedSeason = ref.watch(selectedSeasonProvider(id));

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Column(
        children: [
          FreshnessHeader(
            queryKeys: [
              QueryKeys.showDetail(id),
              QueryKeys.seasonEpisodes(id, selectedSeason),
            ],
            topInset: freshnessTopInset(context, appBarHeight: 0),
          ),
          Expanded(
            child: showAsync.when(
              data: (show) => _buildContent(context, ref, show),
              loading: () => _buildLoadingState(context),
              error: (error, stack) => _buildErrorState(context, ref, error),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          expandedHeight: 350,
          pinned: true,
          backgroundColor: AppColors.background,
          leading: _buildBackButton(context),
          flexibleSpace: FlexibleSpaceBar(
            background: Container(
              color: AppColors.surface,
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.shimmerBase,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  height: 24,
                  width: 200,
                  decoration: BoxDecoration(
                    color: AppColors.shimmerBase,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  height: 100,
                  decoration: BoxDecoration(
                    color: AppColors.shimmerBase,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorState(BuildContext context, WidgetRef ref, Object error) {
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          expandedHeight: 200,
          pinned: true,
          backgroundColor: AppColors.background,
          leading: _buildBackButton(context),
        ),
        SliverFillRemaining(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.error.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.error_outline_rounded,
                      size: 48,
                      color: AppColors.error,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Failed to load TV show',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    error.toString(),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: () => ref
                        .read(showDetailControllerProvider(id).notifier)
                        .refresh(),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try Again'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context, WidgetRef ref, ShowDetail show) {
    return CustomScrollView(
      slivers: [
        _buildHeroSection(context, ref, show),
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              _buildMetadata(context, show),
              const SizedBox(height: 24),
              if (show.overview != null) ...[
                _buildOverview(context, show),
                const SizedBox(height: 24),
              ],
              if (show.genres.isNotEmpty) ...[
                _buildGenres(context, show),
                const SizedBox(height: 24),
              ],
              if (show.seasons.isNotEmpty)
                _buildSeasonSelector(context, ref, show),
              const SizedBox(height: 8),
            ],
          ),
        ),
        _buildEpisodeList(context, ref),
        const SliverToBoxAdapter(
          child: SizedBox(height: 32),
        ),
      ],
    );
  }

  Widget _buildBackButton(BuildContext context) {
    return Padding(
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
    );
  }

  Widget _buildHeroSection(
      BuildContext context, WidgetRef ref, ShowDetail show) {
    return SliverAppBar(
      expandedHeight: 380,
      pinned: true,
      stretch: true,
      backgroundColor: AppColors.background,
      leading: _buildBackButton(context),
      actions: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Material(
            color: Colors.black.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => ref
                  .read(showDetailControllerProvider(id).notifier)
                  .toggleFavorite(),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  show.isFavorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: show.isFavorite ? AppColors.error : Colors.white,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
      ],
      flexibleSpace: FlexibleSpaceBar(
        stretchModes: const [
          StretchMode.zoomBackground,
          StretchMode.blurBackground,
        ],
        background: Stack(
          fit: StackFit.expand,
          children: [
            // Background image
            if (show.artwork.backdropUrl != null)
              CachedNetworkImage(
                imageUrl: show.artwork.backdropUrl!,
                fit: BoxFit.cover,
                cacheManager: BackdropCacheManager(),
                placeholder: (context, url) => Container(
                  color: AppColors.surface,
                ),
                errorWidget: (context, url, error) => Container(
                  color: AppColors.surface,
                ),
              )
            else
              Container(color: AppColors.surface),

            // Gradient overlay
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

            // Content overlay
            Positioned(
              left: 20,
              right: 20,
              bottom: 20,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Poster
                  _buildPoster(show),
                  const SizedBox(width: 16),
                  // Title and info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          show.title,
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
                        if (show.yearDisplay.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            show.yearDisplay,
                            style:
                                Theme.of(context).textTheme.bodyLarge?.copyWith(
                                      color: AppColors.textSecondary,
                                    ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        _buildQuickStats(context, show),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (show.nextEpisode != null)
                    SmartPlayButton(
                      files: show.nextEpisode!.files,
                      onFileSelected: (file) {
                        final nextEp = show.nextEpisode!;
                        final title = '${show.title} - ${nextEp.episodeCode}';
                        context.push(
                          '/player/episode/${nextEp.id}?fileId=${file.id}&title=${Uri.encodeComponent(title)}&showId=$id&seasonNumber=${nextEp.seasonNumber}',
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPoster(dynamic show) {
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
          child: show.artwork.posterUrl != null
              ? CachedNetworkImage(
                  imageUrl: show.artwork.posterUrl!,
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

  Widget _buildQuickStats(BuildContext context, show) {
    return Row(
      children: [
        _buildStatBadge(
          context,
          Icons.folder_rounded,
          '${show.seasonCount} Season${show.seasonCount != 1 ? 's' : ''}',
        ),
        const SizedBox(width: 12),
        _buildStatBadge(
          context,
          Icons.movie_rounded,
          '${show.episodeCount} Ep',
        ),
        if (show.ratingDisplay.isNotEmpty) ...[
          const SizedBox(width: 12),
          _buildStatBadge(
            context,
            Icons.star_rounded,
            show.ratingDisplay,
            iconColor: Colors.amber,
          ),
        ],
      ],
    );
  }

  Widget _buildStatBadge(
    BuildContext context,
    IconData icon,
    String label, {
    Color? iconColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: iconColor ?? AppColors.textSecondary),
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

  Widget _buildMetadata(BuildContext context, show) {
    final items = <Widget>[];

    if (show.statusDisplay.isNotEmpty) {
      items.add(_buildMetadataChip(
        context,
        show.statusDisplay,
        show.statusDisplay == 'Ended'
            ? AppColors.textSecondary
            : AppColors.success,
      ));
    }

    if (show.contentRating != null) {
      items.add(
          _buildMetadataChip(context, show.contentRating!, AppColors.accent));
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: items,
      ),
    );
  }

  Widget _buildMetadataChip(BuildContext context, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _buildOverview(BuildContext context, show) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Overview',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            show.overview!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                  height: 1.6,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildGenres(BuildContext context, show) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: show.genres.map<Widget>((genre) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              genre,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSeasonSelector(
      BuildContext context, WidgetRef ref, ShowDetail show) {
    final selectedSeason = ref.watch(selectedSeasonProvider(id));
    // Only show seasons that have files available in Mydia
    final availableSeasons = show.seasons.where((s) => s.hasFiles).toList();

    if (availableSeasons.isEmpty) {
      return const SizedBox.shrink();
    }

    // Auto-select first available season if current selection has no files
    final hasSelectedSeasonFiles = availableSeasons.any(
      (s) => s.seasonNumber == selectedSeason,
    );
    if (!hasSelectedSeasonFiles) {
      // Schedule the update for after the current build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref
            .read(selectedSeasonProvider(id).notifier)
            .select(availableSeasons.first.seasonNumber);
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Episodes',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const Spacer(),
              if (isDownloadSupported)
                _BulkDownloadButton(
                  showId: id,
                  show: show,
                  selectedSeason: selectedSeason,
                  availableSeasons: availableSeasons,
                ),
              // Season watched actions render on web too, where downloads are
              // unsupported — so they live outside the isDownloadSupported gate.
              _SeasonActionsButton(
                showId: id,
                selectedSeason: selectedSeason,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 44,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: availableSeasons.length,
            itemBuilder: (context, index) {
              final season = availableSeasons[index];
              final isSelected = season.seasonNumber == selectedSeason;

              return Padding(
                padding: const EdgeInsets.only(right: 10),
                child: _SeasonChip(
                  label: 'Season ${season.seasonNumber}',
                  isSelected: isSelected,
                  onTap: () {
                    ref
                        .read(selectedSeasonProvider(id).notifier)
                        .select(season.seasonNumber);
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEpisodeList(BuildContext context, WidgetRef ref) {
    final selectedSeason = ref.watch(selectedSeasonProvider(id));
    final showAsync = ref.watch(showDetailControllerProvider(id));
    final show = showAsync.value;

    final episodesAsync = ref.watch(
      seasonEpisodesControllerProvider(
        showId: id,
        seasonNumber: selectedSeason,
      ),
    );

    return episodesAsync.when(
      data: (episodes) {
        if (episodes.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: Center(
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceVariant.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.tv_off_rounded,
                        size: 48,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No episodes found',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'This season has no episodes available',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.textSecondary,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final episode = episodes[index];
                return EpisodeCard(
                  key: ValueKey(episode.id),
                  episode: episode,
                  showTitle: show?.title ?? 'Unknown Show',
                  showId: show?.id,
                  showPosterUrl: show?.artwork.posterUrl,
                  onTap: episode.hasFile
                      ? () async {
                          if (episode.files.isNotEmpty) {
                            final screenWidth =
                                MediaQuery.sizeOf(context).width;
                            final deviceContext =
                                await DeviceContext.detect(screenWidth);
                            final selectedFile = MediaFileSelector.selectBest(
                              episode.files,
                              deviceContext,
                            );
                            if (selectedFile != null && context.mounted) {
                              final showAsync =
                                  ref.read(showDetailControllerProvider(id));
                              final show = showAsync.value;
                              final title = show != null
                                  ? '${show.title} - ${episode.episodeCode}'
                                  : episode.title;
                              context.push(
                                '/player/episode/${episode.id}?fileId=${selectedFile.id}&title=${Uri.encodeComponent(title)}&showId=$id&seasonNumber=${episode.seasonNumber}',
                              );
                            }
                          }
                        }
                      : null,
                );
              },
              childCount: episodes.length,
            ),
          ),
        );
      },
      loading: () => const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (error, stack) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.error_outline_rounded,
                    size: 32,
                    color: AppColors.error,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Failed to load episodes',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  error.toString(),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BulkDownloadButton extends ConsumerWidget {
  final String showId;
  final ShowDetail show;
  final int selectedSeason;
  final List<SeasonInfo> availableSeasons;

  const _BulkDownloadButton({
    required this.showId,
    required this.show,
    required this.selectedSeason,
    required this.availableSeasons,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(
        Icons.download_rounded,
        color: AppColors.textSecondary,
        size: 22,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      style: const ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      onSelected: (value) {
        if (value == 'season') {
          _handleBulkDownload(
            context,
            ref,
            [selectedSeason],
          );
        } else if (value == 'all') {
          _handleBulkDownload(
            context,
            ref,
            availableSeasons.map((s) => s.seasonNumber).toList(),
          );
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'season',
          child: Row(
            children: [
              const Icon(Icons.folder_rounded, size: 18),
              const SizedBox(width: 12),
              Text('Download Season $selectedSeason'),
            ],
          ),
        ),
        if (availableSeasons.length > 1)
          const PopupMenuItem(
            value: 'all',
            child: Row(
              children: [
                Icon(Icons.folder_copy_rounded, size: 18),
                SizedBox(width: 12),
                Text('Download All Seasons'),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _handleBulkDownload(
    BuildContext context,
    WidgetRef ref,
    List<int> seasonNumbers,
  ) async {
    // Fetch episodes for all requested seasons
    final allEpisodes = <Episode>[];
    for (final seasonNumber in seasonNumbers) {
      try {
        final episodes = await ref.read(
          seasonEpisodesControllerProvider(
            showId: showId,
            seasonNumber: seasonNumber,
          ).future,
        );
        allEpisodes
            .addAll(episodes.where((e) => e.hasFile && e.files.isNotEmpty));
      } catch (e) {
        debugPrint('Failed to fetch episodes for season $seasonNumber: $e');
      }
    }

    if (allEpisodes.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No downloadable episodes found'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (!context.mounted) return;

    // Show quality dialog using the first episode's ID
    final selectedResolution = await showQualityDownloadDialog(
      context,
      contentType: 'episode',
      contentId: allEpisodes.first.id,
      title: seasonNumbers.length == 1
          ? '${show.title} - Season ${seasonNumbers.first}'
          : '${show.title} - All Seasons',
    );

    if (selectedResolution == null || !context.mounted) return;

    // Get download services
    final downloadJobService = ref.read(unifiedDownloadJobServiceProvider);
    if (downloadJobService == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Download service not available'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    final downloadManager = await ref.read(downloadManagerProvider.future);

    // Build sets for skip checks
    final downloadedMediaIds = <String>{};
    final queueMediaIds = <String>{};

    for (final episode in allEpisodes) {
      if (downloadManager.isMediaDownloaded(episode.id)) {
        downloadedMediaIds.add(episode.id);
      }
    }

    final queueAsync = ref.read(downloadQueueProvider);
    if (queueAsync.hasValue) {
      for (final task in queueAsync.value!) {
        queueMediaIds.add(task.mediaId);
      }
    }

    // Start bulk downloads
    final result = await startBulkEpisodeDownloads(
      episodes: allEpisodes,
      resolution: selectedResolution,
      showId: showId,
      showTitle: show.title,
      showPosterUrl: show.artwork.posterUrl,
      downloadManager: downloadManager,
      downloadJobService: downloadJobService,
      isMediaDownloaded: (id) => downloadedMediaIds.contains(id),
      isMediaInQueue: (id) => queueMediaIds.contains(id),
    );

    if (!context.mounted) return;

    // Show result snackbar
    final message = _buildResultMessage(result);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              result.queued > 0
                  ? Icons.download_rounded
                  : Icons.info_outline_rounded,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor:
            result.queued > 0 ? AppColors.primary : AppColors.textSecondary,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _buildResultMessage(BulkDownloadResult result) {
    if (result.queued == 0 && result.skipped > 0) {
      return 'All ${result.skipped} episodes already downloaded or queued';
    }
    final parts = <String>[];
    parts.add(
        'Queued ${result.queued} episode${result.queued != 1 ? 's' : ''} for download');
    if (result.skipped > 0) {
      parts.add('${result.skipped} already downloaded');
    }
    if (result.failed > 0) {
      parts.add('${result.failed} failed');
    }
    return parts.join(', ');
  }
}

/// Overflow menu in the "Episodes" title row that marks the currently selected
/// season watched or unwatched. Renders on all platforms (including web, where
/// downloads are unsupported), so it sits outside the download-support gate.
class _SeasonActionsButton extends ConsumerWidget {
  final String showId;
  final int selectedSeason;

  const _SeasonActionsButton({
    required this.showId,
    required this.selectedSeason,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(
        Icons.more_vert_rounded,
        color: AppColors.textSecondary,
        size: 22,
      ),
      tooltip: 'Season actions',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      style: const ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      onSelected: (value) => _handleSeasonAction(context, ref, value),
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'season_watched',
          child: Row(
            children: [
              Icon(Icons.visibility_rounded, size: 18),
              SizedBox(width: 12),
              Text('Mark season watched'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'season_unwatched',
          child: Row(
            children: [
              Icon(Icons.visibility_off_rounded, size: 18),
              SizedBox(width: 12),
              Text('Mark season unwatched'),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _handleSeasonAction(
    BuildContext context,
    WidgetRef ref,
    String value,
  ) async {
    final controller = ref.read(
      seasonEpisodesControllerProvider(
        showId: showId,
        seasonNumber: selectedSeason,
      ).notifier,
    );

    try {
      if (value == 'season_watched') {
        await controller.markSeasonWatched();
      } else if (value == 'season_unwatched') {
        await controller.markSeasonUnwatched();
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not update season watched status'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}

class _SeasonChip extends StatefulWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SeasonChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_SeasonChip> createState() => _SeasonChipState();
}

class _SeasonChipState extends State<_SeasonChip>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) {
        _controller.reverse();
        widget.onTap();
      },
      onTapCancel: () => _controller.reverse(),
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: widget.isSelected ? AppColors.primary : AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.isSelected
                  ? AppColors.primary
                  : AppColors.divider.withValues(alpha: 0.3),
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: widget.isSelected ? Colors.white : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
