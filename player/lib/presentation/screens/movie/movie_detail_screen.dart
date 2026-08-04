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
import '../../widgets/cast_actions.dart';
import '../../widgets/cast_button.dart';
import '../../widgets/movie_watched_controls.dart';
import '../../widgets/smart_play_button.dart';

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

  Widget _buildContent(BuildContext context, WidgetRef ref, movie) {
    return CustomScrollView(
      slivers: [
        _buildHeroSection(context, ref, movie),
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              if (movie.isWatched) ...[
                MovieWatchedLine(dateLabel: movie.watchedAtDisplay),
                const SizedBox(height: 24),
              ] else if (movie.hasResumableProgress) ...[
                _buildProgressBar(context, movie),
                const SizedBox(height: 24),
              ],
              if (movie.overview != null) ...[
                _buildOverview(context, movie),
                const SizedBox(height: 24),
              ],
              if (movie.genres.isNotEmpty) ...[
                _buildGenres(context, movie),
                const SizedBox(height: 24),
              ],
              const SizedBox(height: 32),
            ],
          ),
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

  Widget _buildHeroSection(BuildContext context, WidgetRef ref, movie) {
    return SliverAppBar(
      expandedHeight: 380,
      pinned: true,
      stretch: true,
      backgroundColor: AppColors.background,
      leading: _buildBackButton(context),
      actions: [
        if (isDownloadSupported)
          Padding(
            padding: const EdgeInsets.all(8),
            child: _buildAppBarDownloadButton(context, ref, movie),
          ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: MovieWatchedButton(
            watched: movie.isWatched,
            onPressed: () => _toggleWatched(context, ref, movie.isWatched),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Material(
            color: Colors.black.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => ref
                  .read(movieDetailControllerProvider(id).notifier)
                  .toggleFavorite(),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  movie.isFavorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: movie.isFavorite ? AppColors.error : Colors.white,
                ),
              ),
            ),
          ),
        ),
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
                  _buildPoster(movie),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          movie.title,
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
                        if (movie.yearDisplay.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            movie.yearDisplay,
                            style:
                                Theme.of(context).textTheme.bodyLarge?.copyWith(
                                      color: AppColors.textSecondary,
                                    ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        _buildQuickStats(context, movie),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SmartPlayButton(
                    files: movie.files,
                    onFileSelected: (file) {
                      context.push(
                        '/player/movie/${movie.id}?fileId=${file.id}&title=${Uri.encodeComponent(movie.title)}',
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

  Widget _buildPoster(dynamic movie) {
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
          child: movie.artwork.posterUrl != null
              ? CachedNetworkImage(
                  imageUrl: movie.artwork.posterUrl!,
                  fit: BoxFit.cover,
                  cacheManager: PosterCacheManager(),
                  placeholder: (context, url) => Container(
                    color: AppColors.surfaceVariant,
                  ),
                  errorWidget: (context, url, error) => Container(
                    color: AppColors.surfaceVariant,
                    child: const Icon(Icons.movie_rounded,
                        color: AppColors.textSecondary),
                  ),
                )
              : Container(
                  color: AppColors.surfaceVariant,
                  child: const Icon(Icons.movie_rounded,
                      color: AppColors.textSecondary),
                ),
        ),
      ),
    );
  }

  Widget _buildQuickStats(BuildContext context, movie) {
    return Row(
      children: [
        if (movie.runtimeDisplay.isNotEmpty) ...[
          _buildStatBadge(
            context,
            Icons.schedule_rounded,
            movie.runtimeDisplay,
          ),
          const SizedBox(width: 12),
        ],
        if (movie.ratingDisplay.isNotEmpty) ...[
          _buildStatBadge(
            context,
            Icons.star_rounded,
            movie.ratingDisplay,
            iconColor: Colors.amber,
          ),
          const SizedBox(width: 12),
        ],
        if (movie.contentRating != null)
          _buildStatBadge(
            context,
            Icons.shield_rounded,
            movie.contentRating!,
          ),
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

  Widget _buildAppBarDownloadButton(
      BuildContext context, WidgetRef ref, movie) {
    final isDownloadedAsync = ref.watch(isMediaDownloadedProvider(movie.id));
    final isDownloaded = isDownloadedAsync.value ?? false;
    final hasFiles = movie.files.isNotEmpty;

    return Material(
      color: Colors.black.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: hasFiles
            ? () async {
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
                    final downloadService =
                        ref.read(unifiedDownloadJobServiceProvider);
                    final downloadManager =
                        await ref.read(downloadManagerProvider.future);

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
                            final status =
                                await downloadService.prepareDownload(
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
                            final status =
                                await downloadService.getJobStatus(jobId);
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
            : null,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            isDownloaded ? Icons.download_done_rounded : Icons.download_rounded,
            color: isDownloaded ? AppColors.success : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildProgressBar(BuildContext context, movie) {
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: percentage.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: AppColors.surfaceVariant,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(AppColors.primary),
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
      ),
    );
  }

  Widget _buildOverview(BuildContext context, movie) {
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
            movie.overview!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                  height: 1.6,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildGenres(BuildContext context, movie) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: movie.genres.map<Widget>((genre) {
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
}
