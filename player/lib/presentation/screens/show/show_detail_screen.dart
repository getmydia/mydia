import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../widgets/detail_art_image.dart';
import '../../../core/layout/dock_insets.dart';
import '../../../core/downloads/download_providers.dart';
import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../detail/detail_actions.dart';
import '../detail/detail_links.dart';
import '../detail/detail_hero.dart';
import '../detail/detail_providers.dart';
import '../detail/detail_screen_frame.dart';
import '../detail/detail_sections.dart';
import '../detail/detail_similar_rail.dart';
import '../detail/download_metadata.dart';
import '../detail/start_download.dart';
import '../../../domain/sources/item.dart';
import 'show_season_section.dart';
import 'show_selection_providers.dart';
import '../../widgets/detail_hero_app_bar.dart';
import '../../widgets/shell_rail_inset.dart';
import '../../../core/player/resume_plan.dart';
import '../../../core/theme/colors.dart';
import '../../widgets/cast_rail.dart';
import '../../widgets/detail_action_row.dart';
import '../../widgets/hero_play_control.dart';
import '../../widgets/media_info/media_info_sheet.dart';

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
  const ShowDetailScreen.target({
    super.key,
    required this.target,
    this.initialSeason,
    this.initialEpisode,
  });

  final DetailTarget target;

  /// Opened from a season or an episode: start on that season rather than
  /// next up.
  final int? initialSeason;

  /// Opened from an episode: its id, selected in the hero rather than next up.
  final String? initialEpisode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showAsync = ref.watch(showViewProvider(target));
    // Held from the first frame so the selections `_InitialSelectionSeed`
    // makes survive while the show is still loading: both providers are
    // autoDispose, and nothing else listens to them until the show lands.
    ref.watch(selectedSeasonProvider(target.ref));
    ref.watch(selectedEpisodeProvider(target.ref));

    return _InitialSelectionSeed(
      show: target.ref,
      season: initialSeason,
      episode: initialEpisode,
      child: DetailScreenFrame<ShowView>(
        target: target,
        value: showAsync,
        noun: 'TV show',
        onRetry: () => ref.read(showActionsProvider(target)).refresh(),
        tintArt: (show) => show.backdrop,
        builder: (context, show) => _buildContent(context, ref, show),
      ),
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

  EpisodeView? _withDetailFiles(WidgetRef ref, EpisodeView? episode) {
    if (episode == null) return null;
    final files = ref.watch(episodeViewProvider(episode.target)).value?.files;
    return files == null || files.isEmpty
        ? episode
        : episode.copyWith(files: files);
  }

  Widget _buildContent(BuildContext context, WidgetRef ref, ShowView show) {
    final key = target.ref;
    final selectedEpisodeId = ref.watch(selectedEpisodeProvider(key));

    // A screen opened on a season or an episode never seeds next up: that
    // would pull the selection back off what it was opened on.
    final nextUpId = show.nextUpEpisodeId;
    final nextUpSeason = show.nextUpSeasonNumber;
    if (selectedEpisodeId == null &&
        initialSeason == null &&
        initialEpisode == null &&
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
    // Season listings carry one stub file per episode. The hero needs the
    // real versions for its quality label, picker and download button, so it
    // reads the selected episode's detail (cached) and keeps the stub until that lands or if it fails.
    final heroEpisode = _withDetailFiles(ref, selectedEpisode);

    return CustomScrollView(
      slivers: [
        _buildHeroSection(context, ref, show, heroEpisode),
        // The hero runs under the rail; everything below it sits beside it.
        ...railInsetSlivers([
          SliverToBoxAdapter(
            child: _buildEpisodeHeroBody(context, ref, show, heroEpisode),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 28),
              child: CastRail(members: show.cast),
            ),
          ),
          SliverToBoxAdapter(
            child: DetailSimilarRail(show: show),
          ),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 20),
                // Status chip only. Content rating and genres live in the
                // hero's tag row; repeating them here rendered each twice.
                DetailMetadataWrap(chips: [
                  if (show.status case final status? when status.isNotEmpty)
                    DetailMetadataChip(
                      label: status,
                      color: status == 'Ended'
                          ? AppColors.textSecondary
                          : AppColors.success,
                    ),
                ]),
                const SizedBox(height: 24),
                if (show.overview case final overview?) ...[
                  DetailOverview(overview: overview),
                  const SizedBox(height: 24),
                ],
                if (show.seasons.isNotEmpty) ShowSeasonSection(show: show),
                const SizedBox(height: 8),
              ],
            ),
          ),
          ShowEpisodeList(show: show, onRevealHero: _revealHero),
          const SliverDockGap(),
        ]),
      ],
    );
  }

  Widget _buildHeroSection(
    BuildContext context,
    WidgetRef ref,
    ShowView show,
    EpisodeView? selectedEpisode,
  ) {
    return detailHeroAppBar(
      context: context,
      expandedHeight: 380,
      back: const DetailHeroBackButton(),
      background: DetailHeroBackground(
        art: show.backdrop,
        slot: ArtSlot.backdrop,
        overlay: DetailHeroTitle(
          title: show.title,
          subtitle: show.yearDisplay,
          poster: show.poster == null
              ? null
              : DetailArtImage(art: show.poster, slot: ArtSlot.poster),
          below: selectedEpisode == null
              ? null
              : _buildEpisodeContextPill(show, selectedEpisode),
          action: selectedEpisode == null
              ? null
              : _buildHeroPlayControl(context, ref, show, selectedEpisode),
        ),
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

  /// The hero's Play affordance.
  Widget _buildHeroPlayControl(
    BuildContext context,
    WidgetRef ref,
    ShowView show,
    EpisodeView episode,
  ) {
    return HeroPlayControl(
      resume: _resumeSeconds(episode) != null,
      files: episode.files,
      onFileSelected: (file) => pushPlayer(
        context,
        ref,
        target,
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

    return DetailHeroBody(
      actionColumn: (compact) => _buildActionColumn(
        context,
        ref,
        show,
        selectedEpisode,
        compact: compact,
      ),
      tagColumn: _buildTagColumn(show, selectedEpisode),
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
    final item = episode.target.ref;
    final canDownload = isDownloadSupported &&
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
          ? () => startItemDownload(context, ref,
              item: item, metadata: episodeDownloadMetadata(episode))
          : null,
      trailerUrl: show.trailerUrl,
      showDownload: canDownload,
      // Per-episode, not per-show: the hero's Download action downloads
      // the selected episode.
      isDownloaded: canDownload &&
          (ref.watch(isItemDownloadedProvider(item)).value ?? false),
      onShowMediaInfo: !show.features.contains(DetailFeature.mediaInfo) ||
              episode.files.isEmpty
          ? null
          : () => showMediaInfo(context: context, item: item),
    );
  }

  Widget _buildTagColumn(ShowView show, EpisodeView episode) {
    return DetailTagColumn(
      tags: [
        if (episode.runtimeDisplay.isNotEmpty) episode.runtimeDisplay,
        if (episode.files.firstOrNull?.resolution case final resolution?)
          resolution,
        if (show.contentRating case final rating?) rating,
        ...show.genres,
      ],
      overview: episode.overview,
      rating: show.ratingDisplay,
    );
  }
}

/// Selects [season] and [episode] once, on the first frame of a screen opened
/// from a season or an episode. The latch lives in this State, so a later tap
/// is never reverted.
class _InitialSelectionSeed extends ConsumerStatefulWidget {
  const _InitialSelectionSeed({
    required this.show,
    required this.season,
    required this.episode,
    required this.child,
  });

  final ItemRef show;
  final int? season;
  final String? episode;
  final Widget child;

  @override
  ConsumerState<_InitialSelectionSeed> createState() =>
      _InitialSelectionSeedState();
}

class _InitialSelectionSeedState extends ConsumerState<_InitialSelectionSeed> {
  @override
  void initState() {
    super.initState();
    final season = widget.season;
    final episode = widget.episode;
    if (season == null && episode == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (season != null) {
        ref.read(selectedSeasonProvider(widget.show).notifier).select(season);
      }
      if (episode != null) {
        ref.read(selectedEpisodeProvider(widget.show).notifier).select(episode);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
