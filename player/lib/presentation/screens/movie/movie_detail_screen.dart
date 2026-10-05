import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../widgets/detail_art_image.dart';
import '../../../core/layout/dock_insets.dart';
import '../../../core/layout/window_chrome_inset.dart';
import '../../widgets/detail_hero_app_bar.dart';
import '../../widgets/freshness_header.dart';
import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../core/downloads/download_providers.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../detail/detail_links.dart';
import '../detail/detail_providers.dart';
import '../detail/detail_similar_rail.dart';
import '../detail/mydia_downloads.dart';
import '../../../domain/models/download_request.dart';
import '../../../domain/sources/item.dart';
import '../../widgets/cast_rail.dart';
import '../../widgets/detail_action_row.dart';
import '../../widgets/media_info/media_info_sheet.dart';
import '../../widgets/movie_watched_controls.dart';
import '../../widgets/hero_play_control.dart';
import '../../widgets/toast/toaster.dart';

/// Below this width the hero's action column and tag column stack instead
/// of sitting side by side. Matches the wide-layout mockup's tablet/desktop
/// target — see docs/superpowers/specs/2026-08-05-player-detail-page-infuse-redesign-design.md.
const double _kHeroBreakpoint = 700;

class MovieDetailScreen extends ConsumerWidget {
  MovieDetailScreen({super.key, required String id})
      : target = MydiaTarget(DetailKind.movie, id);

  const MovieDetailScreen.target({super.key, required this.target});

  final DetailTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final movieAsync = ref.watch(movieViewProvider(target));

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
              child: movieAsync.when(
                data: (movie) => _buildContent(context, ref, movie),
                loading: () => _buildLoadingState(context),
                error: (error, stack) => _buildErrorState(context, ref, error),
              ),
            ),
          ],
        ),
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
          .read(movieActionsProvider(target))
          .setWatched(!currentlyWatched);
    } catch (_) {
      if (context.mounted) {
        showToast(
          context,
          'Could not update watched status',
          kind: ToastKind.error,
        );
      }
    }
  }

  /// Exposes [_buildLoadingState] for
  /// `detail_screen_inset_test.dart`: that test proves the back button
  /// clears the window chrome in this transient state too, not only in the
  /// loaded hero, without needing `movieDetailControllerProvider`'s GraphQL
  /// stream to reach the loading branch.
  @visibleForTesting
  Widget loadingStateForTest(BuildContext context) =>
      _buildLoadingState(context);

  /// Exposes [_buildErrorState] for the same reason as
  /// [loadingStateForTest]. Needs a real [WidgetRef] because the "Try Again"
  /// button reads `movieDetailControllerProvider(id).notifier` from it, even
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
                    onPressed: () =>
                        ref.read(movieActionsProvider(target)).refresh(),
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

  Widget _buildContent(BuildContext context, WidgetRef ref, MovieView movie) {
    return CustomScrollView(
      slivers: [
        _buildHeroSection(context, ref, movie),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 24),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= _kHeroBreakpoint;
                final actionColumn =
                    _buildActionColumn(context, ref, movie, compact: wide);
                final tagColumn = _buildTagColumn(context, movie);

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
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 28),
            child: CastRail(members: movie.cast),
          ),
        ),
        SliverToBoxAdapter(child: DetailSimilarRail(movie: movie)),
        const SliverDockGap(),
      ],
    );
  }

  Widget _buildActionColumn(
    BuildContext context,
    WidgetRef ref,
    MovieView movie, {
    required bool compact,
  }) {
    final mydia = movie.mydia;
    final canDownload = isDownloadSupported &&
        mydia != null &&
        movie.features.contains(DetailFeature.download) &&
        movie.files.isNotEmpty;
    return DetailActionRow(
      compact: compact,
      watched: movie.isWatched,
      showWatched: movie.features.contains(DetailFeature.watched),
      onToggleWatched: () => _toggleWatched(context, ref, movie.isWatched),
      isFavorite: movie.isFavorite,
      showFavorite: movie.features.contains(DetailFeature.favorite),
      onToggleFavorite: () =>
          ref.read(movieActionsProvider(target)).toggleFavorite(),
      onDownload: canDownload
          ? () => startMydiaMovieDownload(context, ref, mydia)
          : null,
      trailerUrl: movie.trailerUrl,
      showDownload: canDownload,
      isDownloaded: mydia == null
          ? false
          : ref
                  .watch(isItemDownloadedProvider(
                      homeMydiaRef(ItemKind.movie, mydia.id)))
                  .value ??
              false,
      onShowMediaInfo: mydia == null ||
              !movie.features.contains(DetailFeature.mediaInfo) ||
              movie.files.isEmpty
          ? null
          : () => showMediaInfo(
                context: context,
                id: mydia.id,
                target: MediaInfoTarget.movie,
              ),
    );
  }

  Widget _buildTagColumn(BuildContext context, MovieView movie) {
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

  Widget _buildProgressBar(BuildContext context, MovieView movie) {
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

  Widget _buildHeroSection(
      BuildContext context, WidgetRef ref, MovieView movie) {
    return detailHeroAppBar(
      context: context,
      expandedHeight: 380,
      back: const DetailHeroBackButton(),
      background: Stack(
        fit: StackFit.expand,
        children: [
          DetailArtImage(
            art: movie.backdrop,
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
                _buildHeroPlayControl(context, ref, movie),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The hero's Play affordance, extracted (like the other `_buildX` helpers
  /// in this file) for readability: the overlay `Row` it lives in is already
  /// deeply nested inside the `background` `Stack` passed to
  /// `detailHeroAppBar`.
  Widget _buildHeroPlayControl(
    BuildContext context,
    WidgetRef ref,
    MovieView movie,
  ) {
    return HeroPlayControl(
      files: movie.files,
      onFileSelected: (file) => pushPlayer(
        context,
        ref,
        target,
        moviePlayerLocation(movie, file),
      ),
    );
  }
}
