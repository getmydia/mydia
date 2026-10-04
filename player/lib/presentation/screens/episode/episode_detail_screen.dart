import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../widgets/detail_art_image.dart';
import '../../../core/layout/dock_insets.dart';
import '../../../core/layout/window_chrome_inset.dart';
import '../detail/detail_links.dart';
import '../detail/detail_providers.dart';
import '../detail/mydia_downloads.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../../widgets/detail_hero_app_bar.dart';
import '../../widgets/freshness_header.dart';
import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../core/downloads/download_providers.dart';
import '../../../core/theme/colors.dart';
import '../../widgets/media_info/media_info_sheet.dart';
import '../../widgets/smart_play_button.dart';

class EpisodeDetailScreen extends ConsumerWidget {
  EpisodeDetailScreen({super.key, required String id})
      : target = MydiaTarget(DetailKind.episode, id);

  const EpisodeDetailScreen.target({super.key, required this.target});

  final DetailTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodeAsync = ref.watch(episodeViewProvider(target));

    // This is a full-window route (pushed outside the shell), and so the sole
    // owner of the title-bar band here: the body has to sit under
    // `removeBand`, or the ambient `MediaQuery.padding.top` still carries the
    // band on top of the hero's own title row a second time.
    return WindowChromeInsets.removeBand(
      child: Scaffold(
        extendBodyBehindAppBar: true,
        body: Column(
          children: [
            FreshnessHeader(
              queryKeys: freshnessKeys(target),
              topInset: freshnessTopInset(context, appBarHeight: 0),
            ),
            Expanded(
              child: episodeAsync.when(
                data: (episode) => _buildContent(context, ref, episode),
                loading: () => _buildLoadingState(context),
                error: (error, stack) => _buildErrorState(context, ref, error),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Exposes [_buildLoadingState] for
  /// `detail_screen_inset_test.dart`: that test proves the back button
  /// clears the window chrome in this transient state too, not only in the
  /// loaded hero, without needing the episode view's GraphQL stream to
  /// reach the loading branch.
  @visibleForTesting
  Widget loadingStateForTest(BuildContext context) =>
      _buildLoadingState(context);

  /// Exposes [_buildErrorState] for the same reason as
  /// [loadingStateForTest]. Needs a real [WidgetRef] because the "Try Again"
  /// button reads `episodeActionsProvider(target)` from it, even though
  /// nothing is watched during build.
  @visibleForTesting
  Widget errorStateForTest(BuildContext context, WidgetRef ref, Object error) =>
      _buildErrorState(context, ref, error);

  Widget _buildLoadingState(BuildContext context) {
    return CustomScrollView(
      slivers: [
        // The same title row as the loaded hero, so the back button (and the
        // cast button) clear the traffic lights / Linux buttons here too:
        // this state sits under the same `WindowChromeInsets.removeBand` as
        // the rest of the screen, so a plain `leading` slot with its own flat
        // padding has nothing left to push it clear of the band with.
        // `topScrim: false` because the spinner background never had a top
        // darkening gradient and this state does not need one added.
        detailHeroAppBar(
          context: context,
          expandedHeight: 300,
          back: const DetailHeroBackButton(),
          topScrim: false,
          background: Container(
            color: AppColors.surface,
            child: const Center(
              child: CircularProgressIndicator(),
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
        // See the loading state's header above: the same title row as the
        // loaded hero, so the back button clears the window chrome here too.
        detailHeroAppBar(
          context: context,
          expandedHeight: 200,
          back: const DetailHeroBackButton(),
          topScrim: false,
          background: Container(color: AppColors.background),
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
                    onPressed: () =>
                        ref.read(episodeActionsProvider(target)).refresh(),
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
      BuildContext context, WidgetRef ref, EpisodeView episode) {
    final showActionRow = _canDownload(episode) || _canShowMediaInfo(episode);
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
                        context.push(episodePlayerLocation(episode, file));
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
              _buildMetadata(context, episode),
              if (episode.overview != null && episode.overview!.isNotEmpty) ...[
                const SizedBox(height: 24),
                _buildOverview(context, episode),
              ],
              const DockGap(),
            ],
          ),
        ),
      ],
    );
  }

  /// Mydia-only: the download button needs the Mydia episode behind the view.
  /// The button stays (disabled without files) on download-capable platforms.
  bool _canDownload(EpisodeView episode) =>
      isDownloadSupported &&
      episode.mydiaDetail != null &&
      episode.features.contains(DetailFeature.download);

  bool _canShowMediaInfo(EpisodeView episode) =>
      episode.mydiaDetail != null &&
      episode.features.contains(DetailFeature.mediaInfo) &&
      episode.files.isNotEmpty;

  Widget _buildHeroSection(BuildContext context, EpisodeView episode) {
    // Use episode thumbnail if available, otherwise fall back to show backdrop
    final art = episode.still ?? episode.showBackdrop;

    return detailHeroAppBar(
      context: context,
      expandedHeight: 300,
      back: const DetailHeroBackButton(),
      background: Stack(
        fit: StackFit.expand,
        children: [
          // Background image
          if (art != null)
            DetailArtImage(
              art: art,
              slot: ArtSlot.still,
              placeholder: (context) => Container(
                color: AppColors.surface,
              ),
              errorWidget: (context) => Container(
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
        onPressed: () => showMediaInfo(
          context: context,
          id: episode.mydiaDetail!.id,
          target: MediaInfoTarget.episode,
        ),
        icon: const Icon(Icons.info_outline_rounded, color: Colors.white),
        tooltip: 'Media Info',
      ),
    );
  }

  Widget _buildDownloadButton(
      BuildContext context, WidgetRef ref, EpisodeView episode) {
    final mydia = episode.mydiaDetail!;
    final isDownloadedAsync = ref.watch(isMediaDownloadedProvider(mydia.id));
    final isDownloaded = isDownloadedAsync.value ?? false;
    final hasFiles = episode.files.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: IconButton(
        onPressed: hasFiles
            ? () => startMydiaEpisodeDetailDownload(context, ref, mydia)
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

  Widget _buildMetadata(BuildContext context, EpisodeView episode) {
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

  Widget _buildOverview(BuildContext context, EpisodeView episode) {
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
}
