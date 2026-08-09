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
import '../../../domain/models/download.dart';
import '../../../domain/models/episode.dart';
import '../../widgets/episode_rail.dart';
import '../../widgets/freshness_header.dart';
import '../../widgets/quality_download_dialog.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/player/resume_plan.dart';
import '../../../core/theme/colors.dart';
import '../../widgets/cast_actions.dart';
import '../../widgets/cast_button.dart';
import '../../widgets/cast_rail.dart';
import '../../widgets/content_rail.dart';
import '../../widgets/detail_action_row.dart';
import '../../widgets/hero_play_control.dart';

/// Below this width the hero's action column and tag column stack instead
/// of sitting side by side. Matches the movie detail hero's breakpoint — see
/// docs/superpowers/specs/2026-08-05-player-detail-page-infuse-redesign-design.md.
const double _kHeroBreakpoint = 700;

/// The `&resume=` suffix for a hero Play tap, or an empty string when playback
/// should start from the beginning.
///
/// The pre-redesign next-up button asked the server's `nextUp.state` whether
/// this was a continue-watching item. The redesigned hero can point at any
/// episode in the season, not just next-up, so eligibility comes from that
/// episode's own progress: saved progress present, not yet watched, and past
/// the minimum position [shouldPassResume] enforces.
String _resumeSuffix(Episode episode) {
  final progress = episode.progress;
  final pass = shouldPassResume(
    isContinueState: progress != null,
    positionSeconds: progress?.positionSeconds,
    watched: progress?.watched ?? false,
  );
  return pass ? '&resume=${progress!.positionSeconds}' : '';
}

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

  /// Resolves which episode the hero describes: the one matching
  /// [selectedEpisodeId] if it's in the currently-loaded [episodes] list,
  /// otherwise the first episode of that list. The fallback matters for two
  /// real cases: a fully-watched show has no `nextUp`, so the
  /// default-selection seed in `_buildContent` never fires and
  /// `selectedEpisodeId` stays null forever; and switching seasons leaves
  /// `selectedEpisodeId` pointing at an episode from the *previous* season,
  /// which never matches the newly-loaded list. Either case previously left
  /// the hero stuck on a permanent loading spinner instead of falling back
  /// to something sensible.
  Episode? _resolveSelectedEpisode(
    String? selectedEpisodeId,
    List<Episode> episodes,
  ) {
    if (episodes.isEmpty) return null;
    return episodes.where((e) => e.id == selectedEpisodeId).firstOrNull ??
        episodes.first;
  }

  /// Carries the viewport back to the hero after a rail selection.
  ///
  /// The rail sits at the foot of a long page while the hero it feeds sits at
  /// the head, so on a phone a selection lands entirely off-screen and the tap
  /// reads as dead. Drives the enclosing [Scrollable] rather than a
  /// [ScrollController], because [ShowDetailScreen] is a [ConsumerWidget] with
  /// no state to own one; the hero is the first sliver, so the minimum extent
  /// is the hero by construction.
  void _revealHero(BuildContext railContext) {
    final position = Scrollable.maybeOf(railContext)?.position;
    if (position == null || position.pixels <= position.minScrollExtent) {
      return;
    }
    position.animateTo(
      position.minScrollExtent,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _buildContent(BuildContext context, WidgetRef ref, ShowDetail show) {
    final selectedEpisodeId = ref.watch(selectedEpisodeProvider(id));

    if (selectedEpisodeId == null && show.nextUp != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final nextUp = show.nextUp!.episode;
        ref.read(selectedEpisodeProvider(id).notifier).select(nextUp.id);
        ref
            .read(selectedSeasonProvider(id).notifier)
            .select(nextUp.seasonNumber);
      });
    }

    final selectedSeason = ref.watch(selectedSeasonProvider(id));
    final episodesAsync = ref.watch(
      seasonEpisodesControllerProvider(
        showId: id,
        seasonNumber: selectedSeason,
      ),
    );
    final episodes = episodesAsync.value ?? const <Episode>[];
    final selectedEpisode =
        _resolveSelectedEpisode(selectedEpisodeId, episodes);

    return CustomScrollView(
      slivers: [
        _buildHeroSection(context, ref, show, selectedEpisode),
        SliverToBoxAdapter(
          child: _buildEpisodeHeroBody(context, ref, show, selectedEpisode),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 28),
            child: CastRail(members: show.cast),
          ),
        ),
        if (show.similar.isNotEmpty)
          SliverToBoxAdapter(
            child: ContentRail(
              title: 'Similar in your library',
              items: show.similar,
              onItemTap: (itemId, type) => context.push(
                type.toLowerCase() == 'movie'
                    ? '/movie/$itemId'
                    : '/show/$itemId',
              ),
            ),
          ),
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
    BuildContext context,
    WidgetRef ref,
    ShowDetail show,
    Episode? selectedEpisode,
  ) {
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          show.title,
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
                        if (show.yearDisplay.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            show.yearDisplay,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: AppColors.textSecondary),
                          ),
                        ],
                        if (selectedEpisode != null) ...[
                          const SizedBox(height: 8),
                          _buildEpisodeContextPill(show, selectedEpisode),
                        ],
                      ],
                    ),
                  ),
                  // Gap and control are emitted together so a null episode
                  // leaves no dangling spacer.
                  if (selectedEpisode != null) ...[
                    const SizedBox(width: 16),
                    _buildHeroPlayControl(context, show, selectedEpisode),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEpisodeContextPill(ShowDetail show, Episode episode) {
    final isNextUp = show.nextUp?.episode.id == episode.id;
    final label = isNextUp
        ? 'Next Up · S${episode.seasonNumber} E${episode.episodeNumber}'
        : 'S${episode.seasonNumber} · E${episode.episodeNumber}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(20),
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

  /// The hero's Play affordance, extracted (like the other `_buildX` helpers
  /// in this file) for readability: the overlay `Row` it lives in is already
  /// deeply nested inside the `SliverAppBar`'s `FlexibleSpaceBar`/`Stack`.
  Widget _buildHeroPlayControl(
    BuildContext context,
    ShowDetail show,
    Episode episode,
  ) {
    return HeroPlayControl(
      files: episode.files,
      onFileSelected: (file) {
        final title = '${show.title} - ${episode.episodeCode}';
        context.push(
          '/player/episode/${episode.id}?fileId=${file.id}'
          '&title=${Uri.encodeComponent(title)}&showId=$id'
          '&seasonNumber=${episode.seasonNumber}'
          '${_resumeSuffix(episode)}',
        );
      },
    );
  }

  Widget _buildEpisodeHeroBody(
    BuildContext context,
    WidgetRef ref,
    ShowDetail show,
    Episode? selectedEpisode,
  ) {
    if (selectedEpisode == null) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: SizedBox(
          height: 160,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= _kHeroBreakpoint;
          final actionColumn =
              _buildActionColumn(context, ref, show, selectedEpisode);
          final tagColumn = _buildTagColumn(context, show, selectedEpisode);

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
    );
  }

  Widget _buildActionColumn(
    BuildContext context,
    WidgetRef ref,
    ShowDetail show,
    Episode episode,
  ) {
    return DetailActionRow(
      watched: episode.progress?.watched ?? false,
      onToggleWatched: () => episode.progress?.watched ?? false
          ? ref
              .read(seasonEpisodesControllerProvider(
                      showId: id, seasonNumber: episode.seasonNumber)
                  .notifier)
              .markEpisodeUnwatched(episode)
          : ref
              .read(seasonEpisodesControllerProvider(
                      showId: id, seasonNumber: episode.seasonNumber)
                  .notifier)
              .markEpisodeWatched(episode),
      isFavorite: show.isFavorite,
      onToggleFavorite: () =>
          ref.read(showDetailControllerProvider(id).notifier).toggleFavorite(),
      onDownload: () => _startEpisodeDownload(context, ref, show, episode),
      trailerUrl: show.trailerUrl,
      showDownload: isDownloadSupported && episode.files.isNotEmpty,
      // Per-episode, not per-show: the hero's Download action downloads
      // the selected episode.
      isDownloaded:
          ref.watch(isMediaDownloadedProvider(episode.id)).value ?? false,
    );
  }

  Widget _buildTagColumn(
      BuildContext context, ShowDetail show, Episode episode) {
    final tags = <String>[
      if (episode.runtimeDisplay.isNotEmpty) episode.runtimeDisplay,
      if (episode.files.isNotEmpty && episode.files.first.resolution != null)
        episode.files.first.resolution!,
      if (show.contentRating != null) show.contentRating!,
      ...show.genres,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tags.isNotEmpty) ...[
          Wrap(
              spacing: 8,
              runSpacing: 8,
              children: tags.map(_buildTagChip).toList()),
          const SizedBox(height: 18),
        ],
        if (episode.overview != null) ...[
          Text(
            episode.overview!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                  height: 1.6,
                ),
          ),
          const SizedBox(height: 14),
        ],
        if (show.ratingDisplay.isNotEmpty) _buildRatingLine(show.ratingDisplay),
      ],
    );
  }

  Widget _buildTagChip(String label) {
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

  /// Progressive-download flow for the hero's Download action, adapted from
  /// `EpisodeDownloadButton._handleDownload` since the hero isn't that
  /// widget — it needs the same quality-dialog → `startProgressiveDownload`
  /// sequence, just driven by whichever episode is currently selected.
  Future<void> _startEpisodeDownload(
    BuildContext context,
    WidgetRef ref,
    ShowDetail show,
    Episode episode,
  ) async {
    final isDownloadedAsync = ref.read(isMediaDownloadedProvider(episode.id));
    final isDownloaded = isDownloadedAsync.value ?? false;

    if (isDownloaded) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Already downloaded'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } else if (episode.files.isNotEmpty) {
      final selectedResolution = await showQualityDownloadDialog(
        context,
        contentType: 'episode',
        contentId: episode.id,
        title: '${show.title} - ${episode.episodeCode}',
      );

      if (selectedResolution != null && context.mounted) {
        final downloadService = ref.read(unifiedDownloadJobServiceProvider);
        final downloadManager = await ref.read(downloadManagerProvider.future);

        if (downloadService != null) {
          try {
            await downloadManager.startProgressiveDownload(
              mediaId: episode.id,
              title: '${show.title} - ${episode.episodeCode}: ${episode.title}',
              contentType: 'episode',
              resolution: selectedResolution,
              mediaType: MediaType.episode,
              posterUrl: episode.thumbnailUrl,
              overview: episode.overview,
              runtime: episode.runtime,
              seasonNumber: episode.seasonNumber,
              episodeNumber: episode.episodeNumber,
              showId: show.id,
              showTitle: show.title,
              showPosterUrl: show.artwork.posterUrl,
              thumbnailUrl: episode.thumbnailUrl,
              airDate: episode.airDate,
              getDownloadUrl: (jobId) async {
                return await downloadService.getDownloadUrl(jobId);
              },
              prepareDownload: () async {
                final status = await downloadService.prepareDownload(
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

  /// Status chip only. Content rating and genres live in the hero's tag row
  /// now — repeating them here rendered each one twice on the page.
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

        return SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 16),
            // Builder so the tap handler closes over a context *inside* the
            // CustomScrollView. _buildEpisodeList receives _buildContent's
            // context, which sits outside it, and _revealHero needs the
            // enclosing Scrollable.
            child: Builder(
              builder: (railContext) => EpisodeRail(
                episodes: episodes,
                showTitle: show?.title ?? 'Unknown Show',
                showId: show?.id,
                showPosterUrl: show?.artwork.posterUrl,
                // Resolved through the same helper the hero uses, so the rail
                // highlights whichever episode the hero describes — including
                // the fallback cases where the selected id matches nothing in
                // this season's list.
                selectedEpisodeId: _resolveSelectedEpisode(
                  ref.watch(selectedEpisodeProvider(id)),
                  episodes,
                )?.id,
                // The rail picks; the hero plays. Tapping a card used to
                // resolve a file and launch the player, which gave the show
                // page's own tap a different meaning from every other card in
                // the app and left no route to the episode's details.
                onEpisodeTap: (episode) {
                  ref
                      .read(selectedEpisodeProvider(id).notifier)
                      .select(episode.id);
                  if (episode.seasonNumber != selectedSeason) {
                    ref
                        .read(selectedSeasonProvider(id).notifier)
                        .select(episode.seasonNumber);
                  }
                  _revealHero(railContext);
                },
              ),
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
