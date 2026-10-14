import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../widgets/detail_art_image.dart';
import '../../../core/layout/dock_insets.dart';
import '../detail/detail_links.dart';
import '../detail/detail_hero.dart';
import '../detail/detail_providers.dart';
import '../detail/detail_screen_frame.dart';
import '../detail/detail_sections.dart';
import '../detail/download_metadata.dart';
import '../detail/start_download.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../../widgets/detail_hero_app_bar.dart';
import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../core/downloads/download_providers.dart';
import '../../../core/theme/colors.dart';
import '../../widgets/media_info/media_info_sheet.dart';
import '../../widgets/smart_play_button.dart';

class EpisodeDetailScreen extends ConsumerWidget {
  const EpisodeDetailScreen.target({super.key, required this.target});

  final DetailTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DetailScreenFrame<EpisodeView>(
      target: target,
      value: ref.watch(episodeViewProvider(target)),
      noun: 'episode',
      onRetry: () => ref.read(episodeActionsProvider(target)).refresh(),
      tintArt: (episode) => episode.still ?? episode.showBackdrop,
      builder: (context, episode) => _buildContent(context, ref, episode),
    );
  }

  Widget _buildContent(
      BuildContext context, WidgetRef ref, EpisodeView episode) {
    final showActionRow = _canDownload(episode) || _canShowMediaInfo(episode);
    return CustomScrollView(
      // The hero art reaches under the rail; `DetailScreenFrame`'s RailBleed
      // does the clipping.
      clipBehavior: Clip.none,
      slivers: [
        _buildHeroSection(context, ref, episode),
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
                        pushPlayer(
                          context,
                          ref,
                          target,
                          episodePlayerLocation(episode, file),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (showActionRow) ...[
                _buildActionRow(context, ref, episode),
                const SizedBox(height: 20),
              ],
              _buildMetadata(episode),
              if (episode.overview case final overview?
                  when overview.isNotEmpty) ...[
                const SizedBox(height: 24),
                DetailOverview(overview: overview),
              ],
              const DockGap(),
            ],
          ),
        ),
      ],
    );
  }

  /// The button stays (disabled without files) on download-capable platforms.
  bool _canDownload(EpisodeView episode) =>
      isDownloadSupported && episode.features.contains(DetailFeature.download);

  bool _canShowMediaInfo(EpisodeView episode) =>
      episode.features.contains(DetailFeature.mediaInfo) &&
      episode.files.isNotEmpty;

  Widget _buildHeroSection(
    BuildContext context,
    WidgetRef ref,
    EpisodeView episode,
  ) {
    final progress = episode.progress;
    return detailHeroAppBar(
      context: context,
      // Shorter than the movie and show heroes: a still is shorter than a
      // backdrop.
      expandedHeight: 300,
      back: const DetailHeroBackButton(),
      background: DetailHeroBackground(
        // The episode still, or the show's backdrop when there is none.
        art: episode.still ?? episode.showBackdrop,
        slot: ArtSlot.still,
        fallbackIcon: Icons.movie_rounded,
        bottom: progress != null && progress.percentage > 0
            ? LinearProgressIndicator(
                value: progress.percentage / 100,
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation<Color>(
                  progress.watched ? AppColors.success : AppColors.primary,
                ),
                minHeight: 3,
              )
            : null,
      ),
    );
  }

  Widget _buildShowLink(BuildContext context, EpisodeView episode) {
    final showTarget = episode.showTarget;
    if (showTarget == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: InkWell(
        onTap: () {
          context.push(detailLocation(showTarget));
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
                episode.showTitle,
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
  Widget _buildTitleSectionInline(BuildContext context, EpisodeView episode) {
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

  Widget _buildActionRow(
      BuildContext context, WidgetRef ref, EpisodeView episode) {
    final showDownload = _canDownload(episode);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          if (showDownload) _buildDownloadButton(context, ref, episode),
          if (_canShowMediaInfo(episode)) ...[
            if (showDownload) const SizedBox(width: 8),
            _buildMediaInfoButton(context, episode),
          ],
        ],
      ),
    );
  }

  Widget _buildMediaInfoButton(BuildContext context, EpisodeView episode) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: IconButton(
        key: const Key('episode-media-info'),
        onPressed: () =>
            showMediaInfo(context: context, item: episode.target.ref),
        icon: const Icon(Icons.info_outline_rounded, color: Colors.white),
        tooltip: 'Media Info',
      ),
    );
  }

  Widget _buildDownloadButton(
      BuildContext context, WidgetRef ref, EpisodeView episode) {
    final item = episode.target.ref;
    final isDownloadedAsync = ref.watch(isItemDownloadedProvider(item));
    final isDownloaded = isDownloadedAsync.value ?? false;
    final hasFiles = episode.hasFile;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: IconButton(
        onPressed: hasFiles
            ? () => startItemDownload(context, ref,
                item: item, metadata: episodeDownloadMetadata(episode))
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

  Widget _buildMetadata(EpisodeView episode) {
    final progress = episode.progress;
    return DetailMetadataWrap(chips: [
      if (episode.runtimeDisplay.isNotEmpty)
        DetailMetadataChip(
          icon: Icons.schedule_rounded,
          label: episode.runtimeDisplay,
        ),
      if (episode.airDate case final airDate?)
        DetailMetadataChip(
          icon: Icons.calendar_today_rounded,
          label: airDate,
        ),
      if (progress != null && progress.watched)
        const DetailMetadataChip(
          icon: Icons.check_circle_rounded,
          label: 'Watched',
          color: AppColors.success,
        )
      else if (progress != null && progress.percentage > 0)
        DetailMetadataChip(
          icon: Icons.play_circle_outline_rounded,
          label: '${progress.percentage.round()}%',
          color: AppColors.primary,
        ),
    ]);
  }
}
