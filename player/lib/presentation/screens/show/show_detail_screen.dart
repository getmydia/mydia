import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../widgets/detail_art_image.dart';
import '../../../core/layout/dock_insets.dart';
import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/downloads/download_providers.dart';
import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../detail/detail_actions.dart';
import '../detail/detail_links.dart';
import '../detail/detail_providers.dart';
import '../detail/detail_similar_rail.dart';
import '../detail/mydia_downloads.dart';
import 'show_detail_controller.dart';
import 'show_season_section.dart';
import '../../widgets/detail_hero_app_bar.dart';
import '../../widgets/freshness_header.dart';
import '../../../core/player/resume_plan.dart';
import '../../../core/theme/colors.dart';
import '../../widgets/cast_rail.dart';
import '../../widgets/detail_action_row.dart';
import '../../widgets/hero_play_control.dart';
import '../../widgets/media_info/media_info_sheet.dart';

/// Below this width the hero's action column and tag column stack instead
/// of sitting side by side. Matches the movie detail hero's breakpoint — see
/// docs/superpowers/specs/2026-08-05-player-detail-page-infuse-redesign-design.md.
const double _kHeroBreakpoint = 700;

/// The position a hero Play tap resumes from, or null when playback should
/// start from the beginning.
///
/// The pre-redesign next-up button asked the server's `nextUp.state` whether
/// this was a continue-watching item. The redesigned hero can point at any
/// episode in the season, not just next-up, so eligibility comes from that
/// episode's own progress: saved progress present, not yet watched, and past
/// the minimum position [shouldPassResume] enforces.
int? _resumeSeconds(EpisodeView episode) {
  final progress = episode.progress;
  final pass = shouldPassResume(
    isContinueState: progress != null,
    positionSeconds: progress?.positionSeconds,
    watched: progress?.watched ?? false,
  );
  return pass ? progress!.positionSeconds : null;
}

class ShowDetailScreen extends ConsumerWidget {
  ShowDetailScreen({super.key, required String id})
      : target = MydiaTarget(DetailKind.show, id),
        initialSeason = null;

  const ShowDetailScreen.target({
    super.key,
    required this.target,
    this.initialSeason,
  });

  final DetailTarget target;

  /// Opened from a season: start on it rather than next up.
  final int? initialSeason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showAsync = ref.watch(showViewProvider(target));
    final selectedSeason = ref.watch(selectedSeasonProvider(target.key));

    // This is a full-window route (pushed outside the shell), and so the sole
    // owner of the title-bar band here: the body has to sit under
    // `removeBand`, or the ambient `MediaQuery.padding.top` still carries the
    // band on top of the hero's own title row a second time.
    return _InitialSeasonSeed(
      showKey: target.key,
      season: initialSeason,
      child: WindowChromeInsets.removeBand(
        child: Scaffold(
          extendBodyBehindAppBar: true,
          body: Column(
            children: [
              FreshnessHeader(
                queryKeys: freshnessKeys(target, seasonNumber: selectedSeason),
                topInset: freshnessTopInset(context, appBarHeight: 0),
              ),
              Expanded(
                child: showAsync.when(
                  data: (show) => _buildContent(context, ref, show),
                  loading: () => _buildLoadingState(context),
                  error: (error, stack) =>
                      _buildErrorState(context, ref, error),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Exposes [_buildLoadingState] for
  /// `detail_screen_inset_test.dart`: that test proves the back button
  /// clears the window chrome in this transient state too, not only in the
  /// loaded hero, without needing `showDetailControllerProvider`'s GraphQL
  /// stream to reach the loading branch.
  @visibleForTesting
  Widget loadingStateForTest(BuildContext context) =>
      _buildLoadingState(context);

  /// Exposes [_buildErrorState] for the same reason as
  /// [loadingStateForTest]. Needs a real [WidgetRef] because the "Try Again"
  /// button reads `showActionsProvider(target)` from it, even
  /// though nothing is watched during build.
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
          expandedHeight: 350,
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
                    onPressed: () =>
                        ref.read(showActionsProvider(target)).refresh(),
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

  Widget _buildContent(BuildContext context, WidgetRef ref, ShowView show) {
    final key = target.key;
    final selectedEpisodeId = ref.watch(selectedEpisodeProvider(key));

    // A screen opened on a season never seeds next up: that would pull the
    // selection back off the season it was opened on.
    final nextUpId = show.nextUpEpisodeId;
    final nextUpSeason = show.nextUpSeasonNumber;
    if (selectedEpisodeId == null &&
        initialSeason == null &&
        nextUpId != null &&
        nextUpSeason != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(selectedEpisodeProvider(key).notifier).select(nextUpId);
        ref.read(selectedSeasonProvider(key).notifier).select(nextUpSeason);
      });
    }

    final selectedSeason = ref.watch(selectedSeasonProvider(key));
    final episodesAsync = ref.watch(
      seasonEpisodesViewProvider(
        (show: target, seasonNumber: selectedSeason),
      ),
    );
    final episodes = episodesAsync.value ?? const <EpisodeView>[];
    final selectedEpisode = resolveSelectedEpisode(selectedEpisodeId, episodes);

    return CustomScrollView(
      slivers: [
        _buildHeroSection(context, show, selectedEpisode),
        SliverToBoxAdapter(
          child: _buildEpisodeHeroBody(context, ref, show, selectedEpisode),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 28),
            child: CastRail(members: show.cast),
          ),
        ),
        // Collapsed by default: you open a show to reach its episodes, and a
        // strip of other titles between the cast and the seasons pulls
        // against that.
        SliverToBoxAdapter(
          child: DetailSimilarRail(show: show, collapsible: true),
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
              if (show.seasons.isNotEmpty) ShowSeasonSection(show: show),
              const SizedBox(height: 8),
            ],
          ),
        ),
        ShowEpisodeList(show: show, onRevealHero: _revealHero),
        const SliverDockGap(),
      ],
    );
  }

  Widget _buildHeroSection(
    BuildContext context,
    ShowView show,
    EpisodeView? selectedEpisode,
  ) {
    return detailHeroAppBar(
      context: context,
      expandedHeight: 380,
      back: const DetailHeroBackButton(),
      background: Stack(
        fit: StackFit.expand,
        children: [
          // Background image
          DetailArtImage(
            art: show.backdrop,
            slot: ArtSlot.backdrop,
            placeholder: (_) => Container(color: AppColors.surface),
            errorWidget: (_) => Container(color: AppColors.surface),
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
    );
  }

  Widget _buildEpisodeContextPill(ShowView show, EpisodeView episode) {
    final isNextUp = show.nextUpEpisodeId == episode.id;
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
  /// deeply nested inside the `background` `Stack` passed to
  /// `detailHeroAppBar`.
  Widget _buildHeroPlayControl(
    BuildContext context,
    ShowView show,
    EpisodeView episode,
  ) {
    return HeroPlayControl(
      files: episode.files,
      onFileSelected: (file) => context.push(
        episodePlayerLocation(
          episode,
          file,
          resumeSeconds: _resumeSeconds(episode),
        ),
      ),
    );
  }

  Widget _buildEpisodeHeroBody(
    BuildContext context,
    WidgetRef ref,
    ShowView show,
    EpisodeView? selectedEpisode,
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
          final actionColumn = _buildActionColumn(
            context,
            ref,
            show,
            selectedEpisode,
            compact: wide,
          );
          final tagColumn = _buildTagColumn(context, show, selectedEpisode);

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      actionColumn,
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
    ShowView show,
    EpisodeView episode, {
    required bool compact,
  }) {
    final seasonKey = (show: target, seasonNumber: episode.seasonNumber);
    final mydiaShow = show.mydia;
    final mydiaEpisode = episode.mydia;
    final canDownload = isDownloadSupported &&
        mydiaShow != null &&
        mydiaEpisode != null &&
        show.features.contains(DetailFeature.download) &&
        episode.files.isNotEmpty;
    return DetailActionRow(
      compact: compact,
      watched: episode.watched,
      showWatched: show.features.contains(DetailFeature.watched),
      // No failure toast, as before: the hero toggle never raised one.
      onToggleWatched: () => ref.read(seasonActionsProvider(seasonKey)).episode(
            episode,
            episode.watched
                ? EpisodeWatchedAction.unwatched
                : EpisodeWatchedAction.watched,
          ),
      isFavorite: show.isFavorite,
      showFavorite: show.features.contains(DetailFeature.favorite),
      onToggleFavorite: () =>
          ref.read(showActionsProvider(target)).toggleFavorite(),
      onDownload: canDownload
          ? () => startMydiaEpisodeDownload(
                context,
                ref,
                episode: mydiaEpisode,
                showId: mydiaShow.id,
                showTitle: mydiaShow.title,
                showPosterUrl: mydiaShow.artwork.posterUrl,
              )
          : null,
      trailerUrl: show.trailerUrl,
      showDownload: canDownload,
      // Per-episode, not per-show: the hero's Download action downloads
      // the selected episode.
      isDownloaded: mydiaEpisode == null
          ? false
          : ref.watch(isMediaDownloadedProvider(mydiaEpisode.id)).value ??
              false,
      onShowMediaInfo: mydiaEpisode == null ||
              !show.features.contains(DetailFeature.mediaInfo) ||
              episode.files.isEmpty
          ? null
          : () => showMediaInfo(
                context: context,
                id: mydiaEpisode.id,
                target: MediaInfoTarget.episode,
              ),
    );
  }

  Widget _buildTagColumn(
      BuildContext context, ShowView show, EpisodeView episode) {
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

  /// Status chip only. Content rating and genres live in the hero's tag row
  /// now — repeating them here rendered each one twice on the page.
  Widget _buildMetadata(BuildContext context, ShowView show) {
    final items = <Widget>[];
    final status = show.status;

    if (status != null && status.isNotEmpty) {
      items.add(_buildMetadataChip(
        context,
        status,
        status == 'Ended' ? AppColors.textSecondary : AppColors.success,
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

  Widget _buildOverview(BuildContext context, ShowView show) {
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
}

/// Selects [season] once, on the first frame of a screen opened from a season.
/// The latch lives in this State, so a later season tap is never reverted.
class _InitialSeasonSeed extends ConsumerStatefulWidget {
  const _InitialSeasonSeed({
    required this.showKey,
    required this.season,
    required this.child,
  });

  final String showKey;
  final int? season;
  final Widget child;

  @override
  ConsumerState<_InitialSeasonSeed> createState() => _InitialSeasonSeedState();
}

class _InitialSeasonSeedState extends ConsumerState<_InitialSeasonSeed> {
  @override
  void initState() {
    super.initState();
    final season = widget.season;
    if (season == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(selectedSeasonProvider(widget.showKey).notifier).select(season);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
