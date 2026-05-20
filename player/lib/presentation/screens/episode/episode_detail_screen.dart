import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/cache/poster_cache_manager.dart';
import 'episode_detail_controller.dart';
import '../../../domain/models/episode_detail.dart';
import '../../widgets/quality_download_dialog.dart';
import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../core/downloads/download_providers.dart';
import '../../../core/downloads/download_job_providers.dart';
import '../../../domain/models/download.dart';
import '../../../core/theme/colors.dart';
import '../../widgets/smart_play_button.dart';
import '../../widgets/torrent_stream_picker.dart';
import '../../../core/p2p/local_proxy_service.dart';
import '../../../core/connection/connection_provider.dart';
import '../../../core/graphql/graphql_provider.dart';

class EpisodeDetailScreen extends ConsumerWidget {
  final String id;

  const EpisodeDetailScreen({
    super.key,
    required this.id,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodeAsync = ref.watch(episodeDetailControllerProvider(id));

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: episodeAsync.when(
        data: (episode) => _buildContent(context, ref, episode),
        loading: () => _buildLoadingState(context),
        error: (error, stack) => _buildErrorState(context, ref, error),
      ),
    );
  }

  Widget _buildLoadingState(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          expandedHeight: 300,
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
                  height: 32,
                  width: 100,
                  decoration: BoxDecoration(
                    color: AppColors.shimmerBase,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  height: 28,
                  width: 250,
                  decoration: BoxDecoration(
                    color: AppColors.shimmerBase,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.shimmerBase,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                const SizedBox(height: 24),
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
                    'Failed to load episode',
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
                        .read(episodeDetailControllerProvider(id).notifier)
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

  Widget _buildContent(
      BuildContext context, WidgetRef ref, EpisodeDetail episode) {
    return CustomScrollView(
      slivers: [
        _buildHeroSection(context, episode),
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              _buildShowLink(context, episode),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: _buildTitleSectionInline(context, episode),
                    ),
                    const SizedBox(width: 12),
                    SmartPlayButton(
                      files: episode.files,
                      onFileSelected: (file) {
                        context.push(
                          '/player/episode/${episode.id}?fileId=${file.id}&title=${Uri.encodeComponent(episode.fullTitle)}&showId=${episode.show.id}&seasonNumber=${episode.seasonNumber}',
                        );
                      },
                    ),
                    if (episode.files.isEmpty) ...[
                      const SizedBox(width: 12),
                      _buildStreamButton(context, ref, episode),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (isDownloadSupported) ...[
                _buildDownloadRow(context, ref, episode),
                const SizedBox(height: 20),
              ],
              _buildMetadata(context, episode),
              if (episode.overview != null && episode.overview!.isNotEmpty) ...[
                const SizedBox(height: 24),
                _buildOverview(context, episode),
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

  Widget _buildHeroSection(BuildContext context, EpisodeDetail episode) {
    // Use episode thumbnail if available, otherwise fall back to show backdrop
    final imageUrl = episode.thumbnailUrl ?? episode.show.artwork.backdropUrl;

    return SliverAppBar(
      expandedHeight: 300,
      pinned: true,
      stretch: true,
      backgroundColor: AppColors.background,
      leading: _buildBackButton(context),
      flexibleSpace: FlexibleSpaceBar(
        stretchModes: const [
          StretchMode.zoomBackground,
          StretchMode.blurBackground,
        ],
        background: Stack(
          fit: StackFit.expand,
          children: [
            // Background image
            if (imageUrl != null)
              CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                cacheManager: EpisodeThumbnailCacheManager(),
                placeholder: (context, url) => Container(
                  color: AppColors.surface,
                ),
                errorWidget: (context, url, error) => Container(
                  color: AppColors.surface,
                  child: const Icon(
                    Icons.movie_rounded,
                    size: 64,
                    color: AppColors.textSecondary,
                  ),
                ),
              )
            else
              Container(
                color: AppColors.surface,
                child: const Icon(
                  Icons.movie_rounded,
                  size: 64,
                  color: AppColors.textSecondary,
                ),
              ),

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

            // Progress indicator at bottom
            if (episode.progress != null && episode.progress!.percentage > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: episode.progress!.percentage / 100,
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    episode.progress!.watched
                        ? AppColors.success
                        : AppColors.primary,
                  ),
                  minHeight: 3,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildShowLink(BuildContext context, EpisodeDetail episode) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: InkWell(
        onTap: () {
          context.push('/show/${episode.show.id}');
        },
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.arrow_back_ios_rounded,
                size: 14,
                color: AppColors.primary,
              ),
              const SizedBox(width: 4),
              Text(
                episode.show.title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Title section without padding, for use inside a parent Row.
  Widget _buildTitleSectionInline(BuildContext context, EpisodeDetail episode) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Episode code badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.3),
            ),
          ),
          child: Text(
            episode.episodeCode,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: AppColors.primary,
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Episode title
        Text(
          episode.title,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
      ],
    );
  }

  Widget _buildDownloadRow(
      BuildContext context, WidgetRef ref, EpisodeDetail episode) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          _buildDownloadButton(context, ref, episode),
        ],
      ),
    );
  }

  Widget _buildDownloadButton(
      BuildContext context, WidgetRef ref, EpisodeDetail episode) {
    final isDownloadedAsync = ref.watch(isMediaDownloadedProvider(episode.id));
    final isDownloaded = isDownloadedAsync.value ?? false;
    final hasFiles = episode.files.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: IconButton(
        onPressed: hasFiles
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
                    contentType: 'episode',
                    contentId: episode.id,
                    title: episode.fullTitle,
                  );

                  if (selectedResolution != null && context.mounted) {
                    final downloadService =
                        ref.read(unifiedDownloadJobServiceProvider);
                    final downloadManager =
                        await ref.read(downloadManagerProvider.future);

                    if (downloadService != null) {
                      try {
                        await downloadManager.startProgressiveDownload(
                          mediaId: episode.id,
                          title: episode.fullTitle,
                          contentType: 'episode',
                          resolution: selectedResolution,
                          mediaType: MediaType.episode,
                          posterUrl: episode.thumbnailUrl ??
                              episode.show.artwork.posterUrl,
                          overview: episode.overview,
                          runtime: episode.runtime,
                          seasonNumber: episode.seasonNumber,
                          episodeNumber: episode.episodeNumber,
                          showId: episode.show.id,
                          showTitle: episode.show.title,
                          showPosterUrl: episode.show.artwork.posterUrl,
                          thumbnailUrl: episode.thumbnailUrl,
                          airDate: episode.airDate,
                          getDownloadUrl: (jobId) async {
                            return await downloadService.getDownloadUrl(jobId);
                          },
                          prepareDownload: () async {
                            final status =
                                await downloadService.prepareDownload(
                              contentType: 'episode',
                              id: episode.id,
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
        icon: Icon(
          isDownloaded ? Icons.download_done_rounded : Icons.download_rounded,
          color: isDownloaded ? AppColors.success : Colors.white,
        ),
        tooltip: isDownloaded ? 'Downloaded' : 'Download',
        style: IconButton.styleFrom(
          padding: const EdgeInsets.all(14),
        ),
      ),
    );
  }

  Widget _buildMetadata(BuildContext context, EpisodeDetail episode) {
    final items = <Widget>[];

    // Runtime
    if (episode.runtimeDisplay.isNotEmpty) {
      items.add(_buildMetadataChip(
        context,
        Icons.schedule_rounded,
        episode.runtimeDisplay,
      ));
    }

    // Air date
    if (episode.airDate != null) {
      items.add(_buildMetadataChip(
        context,
        Icons.calendar_today_rounded,
        episode.airDate!,
      ));
    }

    // Watched status
    if (episode.progress?.watched == true) {
      items.add(_buildMetadataChip(
        context,
        Icons.check_circle_rounded,
        'Watched',
        color: AppColors.success,
      ));
    } else if (episode.progress != null && episode.progress!.percentage > 0) {
      items.add(_buildMetadataChip(
        context,
        Icons.play_circle_outline_rounded,
        '${episode.progress!.percentage.round()}%',
        color: AppColors.primary,
      ));
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: items,
      ),
    );
  }

  Widget _buildMetadataChip(
    BuildContext context,
    IconData icon,
    String label, {
    Color? color,
  }) {
    final chipColor = color ?? AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: chipColor.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: chipColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: chipColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverview(BuildContext context, EpisodeDetail episode) {
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
            episode.overview!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                  height: 1.6,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildStreamButton(
      BuildContext context, WidgetRef ref, EpisodeDetail episode) {
    return Material(
      color: AppColors.primary,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final result = await showTorrentStreamPicker(
            context,
            contentType: 'episode',
            contentId: episode.id,
            title: episode.fullTitle,
          );

          if (result != null && context.mounted) {
            final sessionId = result['sessionId'] as String;
            final title = result['title'] as String;

            // Get local proxy URL
            final localProxy = ref.read(localProxyServiceProvider);
            final connection = ref.read(connectionProvider);

            if (!localProxy.isRunning) {
              await localProxy.start(
                targetPeer: connection.serverNodeAddr!,
                authToken: ref.read(authTokenProvider).value,
              );
            }

            final streamUrl = localProxy.buildHlsUrl(sessionId);

            if (context.mounted) {
              context.push(
                '/player/episode/${episode.id}?streamUrl=${Uri.encodeComponent(streamUrl)}&title=${Uri.encodeComponent(title)}&sessionId=$sessionId&showId=${episode.show.id}&seasonNumber=${episode.seasonNumber}',
              );
            }
          }
        },
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_arrow_rounded, color: Colors.white),
              SizedBox(width: 4),
              Text(
                'Stream',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
