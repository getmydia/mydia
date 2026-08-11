import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/cache/poster_cache_manager.dart';
import 'movie_detail_controller.dart';
import '../../widgets/freshness_header.dart';
import '../../widgets/quality_download_dialog.dart';
import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../core/downloads/download_providers.dart';
import '../../../core/downloads/download_job_providers.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../domain/models/download.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/models/movie_detail.dart';
import '../../widgets/cast_actions.dart';
import '../../widgets/cast_button.dart';
import '../../widgets/cast_rail.dart';
import '../../widgets/content_rail.dart';
import '../../widgets/detail_action_row.dart';
import '../../widgets/media_info/media_info_sheet.dart';
import '../../widgets/movie_watched_controls.dart';
import '../../widgets/hero_play_control.dart';

/// Below this width the hero's action column and tag column stack instead
/// of sitting side by side. Matches the wide-layout mockup's tablet/desktop
/// target — see docs/superpowers/specs/2026-08-05-player-detail-page-infuse-redesign-design.md.
const double _kHeroBreakpoint = 700;

class MovieDetailScreen extends ConsumerWidget {
  final String id;

  const MovieDetailScreen({
    super.key,
    required this.id,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final movieAsync = ref.watch(movieDetailControllerProvider(id));

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Column(
        children: [
          FreshnessHeader(
            queryKeys: [QueryKeys.movieDetail(id)],
            topInset: freshnessTopInset(context, appBarHeight: 0),
          ),
          Expanded(
            child: movieAsync.when(
              data: (movie) => _buildContent(context, ref, movie),
              loading: () => _buildLoadingState(context),
              error: (error, stack) => _buildErrorState(context, ref, error),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleWatched(
    BuildContext context,
    WidgetRef ref,
    bool currentlyWatched,
  ) async {
    try {
      await ref
          .read(movieDetailControllerProvider(id).notifier)
          .setWatched(!currentlyWatched);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not update watched status'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
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
                    'Failed to load movie',
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
                        .read(movieDetailControllerProvider(id).notifier)
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

  Widget _buildContent(BuildContext context, WidgetRef ref, MovieDetail movie) {
    return CustomScrollView(
      slivers: [
        _buildHeroSection(context, ref, movie),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 24),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= _kHeroBreakpoint;
                final actionColumn = _buildActionColumn(context, ref, movie);
                final tagColumn = _buildTagColumn(context, movie);

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: 248, child: actionColumn),
                            const SizedBox(width: 40),
                            Expanded(child: tagColumn),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            actionColumn,
                            const SizedBox(height: 20),
                            tagColumn,
                          ],
                        ),
                );
              },
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 28),
            child: CastRail(members: movie.cast),
          ),
        ),
        if (movie.similar.isNotEmpty)
          SliverToBoxAdapter(
            child: ContentRail(
              title: 'Similar in your library',
              items: movie.similar,
              onItemTap: (id, type) {
                context.push(
                  type.toLowerCase() == 'movie' ? '/movie/$id' : '/show/$id',
                );
              },
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  Widget _buildActionColumn(
      BuildContext context, WidgetRef ref, MovieDetail movie) {
    return DetailActionRow(
      watched: movie.isWatched,
      onToggleWatched: () => _toggleWatched(context, ref, movie.isWatched),
      isFavorite: movie.isFavorite,
      onToggleFavorite: () =>
          ref.read(movieDetailControllerProvider(id).notifier).toggleFavorite(),
      onDownload: () => _startDownload(context, ref, movie),
      trailerUrl: movie.trailerUrl,
      showDownload: isDownloadSupported && movie.files.isNotEmpty,
      isDownloaded:
          ref.watch(isMediaDownloadedProvider(movie.id)).value ?? false,
      onShowMediaInfo: movie.files.isEmpty
          ? null
          : () => showMediaInfo(
                context: context,
                id: movie.id,
                target: MediaInfoTarget.movie,
              ),
    );
  }

  Widget _buildTagColumn(BuildContext context, MovieDetail movie) {
    final tags = <String>[
      if (movie.runtimeDisplay.isNotEmpty) movie.runtimeDisplay,
      if (movie.files.isNotEmpty && movie.files.first.resolution != null)
        movie.files.first.resolution!,
      if (movie.contentRating != null) movie.contentRating!,
      ...movie.genres,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (movie.isWatched) ...[
          MovieWatchedLine(dateLabel: movie.watchedAtDisplay),
          const SizedBox(height: 18),
        ] else if (movie.hasResumableProgress) ...[
          _buildProgressBar(context, movie),
          const SizedBox(height: 18),
        ],
        if (tags.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: tags.map((tag) => _buildTagChip(context, tag)).toList(),
          ),
          const SizedBox(height: 18),
        ],
        if (movie.overview != null) ...[
          Text(
            movie.overview!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                  height: 1.6,
                ),
          ),
          const SizedBox(height: 14),
        ],
        if (movie.ratingDisplay.isNotEmpty)
          _buildRatingLine(movie.ratingDisplay),
      ],
    );
  }

  Widget _buildTagChip(BuildContext context, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }

  Widget _buildRatingLine(String ratingDisplay) {
    return Row(
      children: [
        const Icon(Icons.star_rounded, size: 16, color: AppColors.primary),
        const SizedBox(width: 6),
        Text(
          ratingDisplay,
          style: const TextStyle(
              fontWeight: FontWeight.bold, color: AppColors.textPrimary),
        ),
        const SizedBox(width: 6),
        const Text('TMDB',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      ],
    );
  }

  Widget _buildProgressBar(BuildContext context, MovieDetail movie) {
    final progress = movie.progress!;
    final percentage = progress.percentage / 100;
    final remaining = progress.durationSeconds != null
        ? progress.durationSeconds! - progress.positionSeconds
        : null;

    String remainingText = '';
    if (remaining != null && remaining > 0) {
      final hours = remaining ~/ 3600;
      final minutes = (remaining % 3600) ~/ 60;
      if (hours > 0) {
        remainingText = '${hours}h ${minutes}m remaining';
      } else {
        remainingText = '${minutes}m remaining';
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: percentage.clamp(0.0, 1.0),
            minHeight: 4,
            backgroundColor: AppColors.surfaceVariant,
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
          ),
        ),
        if (remainingText.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            remainingText,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.textSecondary,
                ),
          ),
        ],
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
      BuildContext context, WidgetRef ref, MovieDetail movie) {
    return SliverAppBar(
      expandedHeight: 380,
      pinned: true,
      stretch: true,
      backgroundColor: AppColors.background,
      leading: _buildBackButton(context),
      actions: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: CastButton(onPressed: () => pickCastDevice(context, ref)),
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
            if (movie.artwork.backdropUrl != null)
              CachedNetworkImage(
                imageUrl: movie.artwork.backdropUrl!,
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          movie.title,
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
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
                        if (movie.yearDisplay.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            movie.yearDisplay,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: AppColors.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  _buildHeroPlayControl(context, movie),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The hero's Play affordance, extracted (like the other `_buildX` helpers
  /// in this file) for readability: the overlay `Row` it lives in is already
  /// deeply nested inside the `SliverAppBar`'s `FlexibleSpaceBar`/`Stack`.
  Widget _buildHeroPlayControl(BuildContext context, MovieDetail movie) {
    return HeroPlayControl(
      files: movie.files,
      onFileSelected: (file) => context.push(
        '/player/movie/${movie.id}?fileId=${file.id}'
        '&title=${Uri.encodeComponent(movie.title)}',
      ),
    );
  }

  Future<void> _startDownload(
    BuildContext context,
    WidgetRef ref,
    MovieDetail movie,
  ) async {
    final isDownloadedAsync = ref.read(isMediaDownloadedProvider(movie.id));
    final isDownloaded = isDownloadedAsync.value ?? false;
    final hasFiles = movie.files.isNotEmpty;
    if (!hasFiles) return;

    if (isDownloaded) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Already downloaded'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } else {
      final selectedResolution = await showQualityDownloadDialog(
        context,
        contentType: 'movie',
        contentId: movie.id,
        title: movie.title,
      );

      if (selectedResolution != null && context.mounted) {
        final downloadService = ref.read(unifiedDownloadJobServiceProvider);
        final downloadManager = await ref.read(downloadManagerProvider.future);

        if (downloadService != null) {
          try {
            await downloadManager.startProgressiveDownload(
              mediaId: movie.id,
              title: movie.title,
              contentType: 'movie',
              resolution: selectedResolution,
              mediaType: MediaType.movie,
              posterUrl: movie.artwork.posterUrl,
              overview: movie.overview,
              runtime: movie.runtime,
              genres: movie.genres,
              rating: movie.rating,
              backdropUrl: movie.artwork.backdropUrl,
              year: movie.year,
              contentRating: movie.contentRating,
              getDownloadUrl: (jobId) async {
                return await downloadService.getDownloadUrl(jobId);
              },
              prepareDownload: () async {
                final status = await downloadService.prepareDownload(
                  contentType: 'movie',
                  id: movie.id,
                  resolution: selectedResolution,
                );
                return (
                  jobId: status.jobId,
                  status: status.status.name,
                  progress: status.progress,
                  fileSize: status.currentFileSize,
                );
              },
              getJobStatus: (jobId) async {
                final status = await downloadService.getJobStatus(jobId);
                return (
                  status: status.status.name,
                  progress: status.progress,
                  fileSize: status.currentFileSize,
                  error: status.error,
                );
              },
              cancelJob: (jobId) async {
                await downloadService.cancelJob(jobId);
              },
            );

            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Download started'),
                  duration: Duration(seconds: 2),
                ),
              );
            }
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Failed to start download: $e'),
                  backgroundColor: AppColors.error,
                ),
              );
            }
          }
        }
      }
    }
  }
}
