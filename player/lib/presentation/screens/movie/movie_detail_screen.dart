import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../widgets/detail_art_image.dart';
import '../../../core/layout/dock_insets.dart';
import '../../widgets/detail_hero_app_bar.dart';
import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../core/downloads/download_providers.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../detail/detail_links.dart';
import '../detail/detail_hero.dart';
import '../detail/detail_providers.dart';
import '../detail/detail_screen_frame.dart';
import '../detail/detail_sections.dart';
import '../detail/detail_similar_rail.dart';
import '../detail/download_metadata.dart';
import '../detail/start_download.dart';
import '../../widgets/cast_rail.dart';
import '../../widgets/detail_action_row.dart';
import '../../widgets/media_info/media_info_sheet.dart';
import '../../widgets/movie_watched_controls.dart';
import '../../widgets/hero_play_control.dart';
import '../../widgets/toast/toaster.dart';

class MovieDetailScreen extends ConsumerWidget {
  const MovieDetailScreen.target({super.key, required this.target});

  final DetailTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DetailScreenFrame<MovieView>(
      target: target,
      value: ref.watch(movieViewProvider(target)),
      noun: 'movie',
      onRetry: () => ref.read(movieActionsProvider(target)).refresh(),
      tintArt: (movie) => movie.backdrop,
      builder: (context, movie) => _buildContent(context, ref, movie),
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

  Widget _buildContent(BuildContext context, WidgetRef ref, MovieView movie) {
    return CustomScrollView(
      slivers: [
        _buildHeroSection(context, ref, movie),
        SliverToBoxAdapter(
          child: DetailHeroBody(
            actionColumn: (compact) =>
                _buildActionColumn(context, ref, movie, compact: compact),
            tagColumn: _buildTagColumn(context, movie),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 28),
            child: CastRail(members: movie.cast),
          ),
        ),
        SliverToBoxAdapter(child: DetailSimilarRail(movie: movie)),
        if (movie.overview case final overview? when overview.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 24),
              child: DetailOverview(overview: overview),
            ),
          ),
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
    final item = movie.target.ref;
    final canDownload = isDownloadSupported &&
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
          ? () => startItemDownload(context, ref,
              item: item, metadata: movieDownloadMetadata(movie))
          : null,
      trailerUrl: movie.trailerUrl,
      showDownload: canDownload,
      isDownloaded: canDownload &&
          (ref.watch(isItemDownloadedProvider(item)).value ?? false),
      onShowMediaInfo: !movie.features.contains(DetailFeature.mediaInfo) ||
              movie.files.isEmpty
          ? null
          : () => showMediaInfo(context: context, item: item),
    );
  }

  Widget _buildTagColumn(BuildContext context, MovieView movie) {
    return DetailTagColumn(
      leading: movie.isWatched
          ? MovieWatchedLine(dateLabel: movie.watchedAtDisplay)
          : movie.hasResumableProgress
              ? _buildProgressBar(context, movie)
              : null,
      tags: [
        if (movie.runtimeDisplay.isNotEmpty) movie.runtimeDisplay,
        if (movie.files.firstOrNull?.resolution case final resolution?)
          resolution,
        if (movie.contentRating case final rating?) rating,
        ...movie.genres,
      ],
      rating: movie.ratingDisplay,
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
      background: DetailHeroBackground(
        art: movie.backdrop,
        slot: ArtSlot.backdrop,
        overlay: DetailHeroTitle(
          title: movie.title,
          subtitle: movie.yearDisplay,
          poster: movie.poster == null
              ? null
              : DetailArtImage(art: movie.poster, slot: ArtSlot.poster),
          action: _buildHeroPlayControl(context, ref, movie),
        ),
      ),
    );
  }

  /// The hero's Play affordance.
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
