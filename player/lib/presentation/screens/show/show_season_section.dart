import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../core/theme/colors.dart';
import '../../../domain/detail/detail_views.dart';
import '../../../domain/models/watch_status.dart';
import '../../widgets/episode_rail.dart';
import '../../widgets/horizontal_wheel_scroll.dart';
import '../../widgets/toast/toaster.dart';
import '../../widgets/watch_indicator.dart';
import '../detail/detail_providers.dart';
import 'show_selection_providers.dart';
import 'source_season_download_button.dart';

/// Resolves which episode the hero describes: the one matching
/// [selectedEpisodeId] if it's in the currently-loaded [episodes] list,
/// otherwise the first episode of that list. The fallback matters for two
/// real cases: a fully-watched show has no next-up episode, so the
/// default-selection seed in the screen never fires and `selectedEpisodeId`
/// stays null forever; and switching seasons leaves `selectedEpisodeId`
/// pointing at an episode from the *previous* season, which never matches the
/// newly-loaded list. Either case would leave the hero stuck on a permanent
/// loading spinner instead of falling back to something sensible.
EpisodeView? resolveSelectedEpisode(
  String? selectedEpisodeId,
  List<EpisodeView> episodes,
) {
  if (episodes.isEmpty) return null;
  return episodes.where((e) => e.id == selectedEpisodeId).firstOrNull ??
      episodes.first;
}

/// The "Episodes" title row (bulk download and season menus) and the season
/// chips beneath it.
class ShowSeasonSection extends ConsumerWidget {
  final ShowView show;

  const ShowSeasonSection({super.key, required this.show});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = show.target.ref;
    final selectedSeason = ref.watch(selectedSeasonProvider(key));
    // Only show seasons that have files available
    final availableSeasons = show.seasons.where((s) => s.hasFiles).toList();

    if (availableSeasons.isEmpty) {
      return const SizedBox.shrink();
    }

    // Auto-select first available season if current selection has no files
    final hasSelectedSeasonFiles = availableSeasons.any(
      (s) => s.number == selectedSeason,
    );
    if (!hasSelectedSeasonFiles) {
      // Schedule the update for after the current build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref
            .read(selectedSeasonProvider(key).notifier)
            .select(availableSeasons.first.number);
      });
    }

    final seasonKey = (show: show.target, seasonNumber: selectedSeason);

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
              if (isDownloadSupported &&
                  show.features.contains(DetailFeature.seasonDownload))
                if (availableSeasons
                        .where((s) => s.number == selectedSeason)
                        .firstOrNull
                    case final season?)
                  SourceSeasonDownloadButton(show: show, season: season),
              // Season watched actions render on web too, where downloads are
              // unsupported, so they live outside the isDownloadSupported gate.
              if (show.features.contains(DetailFeature.watched))
                SeasonActionsButton(seasonKey: seasonKey),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 44,
          child: HorizontalWheelScroll(
            builder: (context, controller) => ListView.builder(
              controller: controller,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: availableSeasons.length,
              itemBuilder: (context, index) {
                final season = availableSeasons[index];
                final unwatched =
                    season.watchStatus?.unwatchedEpisodeCount ?? 0;
                final isSelected = season.number == selectedSeason;

                return Padding(
                  key: ValueKey('season-chip-${season.number}'),
                  padding: const EdgeInsets.only(right: 10),
                  child: _SeasonChip(
                    label: 'Season ${season.number}',
                    unwatched: unwatched,
                    watchStatus: season.watchStatus,
                    isSelected: isSelected,
                    onTap: () {
                      ref
                          .read(selectedSeasonProvider(key).notifier)
                          .select(season.number);
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// The selected season's episode rail, as a sliver.
class ShowEpisodeList extends ConsumerWidget {
  final ShowView show;

  /// Carries the viewport back to the hero after a rail selection. Receives a
  /// context inside the scroll view.
  final void Function(BuildContext railContext) onRevealHero;

  const ShowEpisodeList({
    super.key,
    required this.show,
    required this.onRevealHero,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = show.target.ref;
    final selectedSeason = ref.watch(selectedSeasonProvider(key));

    final episodesAsync = ref.watch(
      seasonEpisodesViewProvider(
        (show: show.target, seasonNumber: selectedSeason),
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
            // CustomScrollView. This widget's own context sits outside it, and
            // revealing the hero needs the enclosing Scrollable.
            child: Builder(
              builder: (railContext) => EpisodeRail(
                episodes: episodes,
                // Resolved through the same helper the hero uses, so the rail
                // highlights whichever episode the hero describes, including
                // the fallback cases where the selected id matches nothing in
                // this season's list.
                selectedEpisodeId: resolveSelectedEpisode(
                  ref.watch(selectedEpisodeProvider(key)),
                  episodes,
                )?.id,
                // The rail picks; the hero plays. Tapping a card used to
                // resolve a file and launch the player, which gave the show
                // page's own tap a different meaning from every other card in
                // the app and left no route to the episode's details.
                onEpisodeTap: (episode) {
                  ref
                      .read(selectedEpisodeProvider(key).notifier)
                      .select(episode.id);
                  if (episode.seasonNumber != selectedSeason) {
                    ref
                        .read(selectedSeasonProvider(key).notifier)
                        .select(episode.seasonNumber);
                  }
                  onRevealHero(railContext);
                },
                onWatchedAction: show.features.contains(DetailFeature.watched)
                    ? (episode, action) => ref
                        .read(
                          seasonActionsProvider(
                            (
                              show: show.target,
                              seasonNumber: episode.seasonNumber,
                            ),
                          ),
                        )
                        .episode(episode, action)
                    : null,
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

/// Overflow menu in the "Episodes" title row that marks the currently selected
/// season watched or unwatched. Renders on all platforms (including web, where
/// downloads are unsupported), so it sits outside the download-support gate.
class SeasonActionsButton extends ConsumerWidget {
  final SeasonKey seasonKey;

  const SeasonActionsButton({super.key, required this.seasonKey});

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
    try {
      // Read at tap time; the provider is auto-dispose.
      final actions = ref.read(seasonActionsProvider(seasonKey));
      if (value == 'season_watched') {
        await actions.setSeasonWatched(true);
      } else if (value == 'season_unwatched') {
        await actions.setSeasonWatched(false);
      }
    } catch (_) {
      if (context.mounted) {
        showToast(
          context,
          'Could not update season watched status',
          kind: ToastKind.error,
        );
      }
    }
  }
}

class _SeasonChip extends StatefulWidget {
  final String label;
  final int unwatched;
  final WatchStatus? watchStatus;
  final bool isSelected;
  final VoidCallback onTap;

  const _SeasonChip({
    required this.label,
    required this.unwatched,
    required this.watchStatus,
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color:
                      widget.isSelected ? Colors.white : AppColors.textPrimary,
                ),
              ),
              if (widget.unwatched > 0) ...[
                const SizedBox(width: 6),
                WatchIndicator(status: widget.watchStatus),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
