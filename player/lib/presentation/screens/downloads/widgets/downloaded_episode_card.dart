import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../download_locations.dart';
import 'download_artwork.dart';
import '../../../../core/cache/poster_cache_manager.dart';
import '../../../../core/layout/breakpoints.dart';
import '../../../../core/playback/local_playback_progress.dart';
import '../../../../core/playback/playback_progress_providers.dart';
import '../../../../core/theme/colors.dart';
import '../../../../core/theme/palette.dart';
import '../../../../domain/models/download.dart';
import '../../../../l10n/l10n.dart';
import '../../../widgets/quality_badge.dart';
import 'series_downloads_dialogs.dart';

/// A landscape (16:9) card for one downloaded episode.
///
/// Geometry is shared with the show detail page's episode rail via
/// [Breakpoints.getEpisodeCardSize], so the two surfaces line up exactly. What
/// differs is the payload: this card is offline-first, so it shows the stored
/// file size and reads resume position from the local Hive store rather than
/// from the server.
///
/// No watched checkmark and no mark-watched menu. Offline there is a position
/// but no explicit watched flag, and inferring one from a percentage threshold
/// is the class of guess that produced the Up Next bug fixed in `cfdcc546`.
class DownloadedEpisodeCard extends ConsumerWidget {
  final DownloadedMedia media;
  final String showId;

  const DownloadedEpisodeCard({
    super.key,
    required this.media,
    required this.showId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final cardSize = Breakpoints.getEpisodeCardSize(context);

    return SizedBox(
      width: cardSize.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => _play(context),
            child: _buildThumbnail(context, ref, cardSize),
          ),
          const SizedBox(height: 8),
          Text(
            media.episodeCode,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: palette.primary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            media.title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            media.fileSizeDisplay,
            style: TextStyle(
              fontSize: 11,
              color: palette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThumbnail(
    BuildContext context,
    WidgetRef ref,
    CardSize cardSize,
  ) {
    final thumbnailUrl = media.thumbnailUrl;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: cardSize.width,
        height: cardSize.height,
        child: Stack(
          children: [
            Positioned.fill(
              child: DownloadArtwork(
                localPath: media.thumbnailPath,
                fallbackUrl: thumbnailUrl,
                cacheManager: EpisodeThumbnailCacheManager(),
                placeholder: (context) => _buildPlaceholder(context),
              ),
            ),
            if (media.quality.isNotEmpty)
              Positioned(
                right: 6,
                bottom: 10,
                child: QualityBadge.resolution(media.quality),
              ),
            _buildResumeBar(context, ref),
            Positioned(
              top: 4,
              right: 4,
              child: _buildMenu(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  /// Reads the offline Hive store synchronously once it has opened. While the
  /// provider is still loading the bar is simply absent, which is correct: an
  /// unwatched episode shows nothing either.
  Widget _buildResumeBar(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final store = ref.watch(playbackProgressStoreProvider).value;
    if (store == null) return const SizedBox.shrink();

    final progress = store.get(progressKey(media.itemRef));
    if (progress == null || progress.durationSeconds <= 0) {
      return const SizedBox.shrink();
    }

    final fraction =
        (progress.positionSeconds / progress.durationSeconds).clamp(0.0, 1.0);

    return Positioned(
      key: const ValueKey('downloaded-episode-resume-bar'),
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        height: 4,
        decoration: BoxDecoration(color: palette.surfaceVariant),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: fraction,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: palette.primary,
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(2),
                bottomRight: Radius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenu(BuildContext context, WidgetRef ref) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: PopupMenuButton<String>(
        key: const ValueKey('downloaded-episode-menu'),
        icon: const Icon(
          Icons.more_vert_rounded,
          color: Colors.white,
          size: 20,
        ),
        tooltip: context.l10n.episodeActionsTooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        style: const ButtonStyle(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        color: context.palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        onSelected: (value) {
          switch (value) {
            case 'play':
              _play(context);
              break;
            case 'delete':
              showDeleteEpisodeDialog(context, ref, media);
              break;
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'play',
            child: Row(
              children: [
                const Icon(Icons.play_arrow_rounded, size: 18),
                const SizedBox(width: 12),
                Text(context.l10n.commonPlay),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                const Icon(
                  Icons.delete_outline_rounded,
                  size: 18,
                  color: AppColors.error,
                ),
                const SizedBox(width: 12),
                Text(context.l10n.commonDelete,
                    style: const TextStyle(color: AppColors.error)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    final palette = context.palette;
    return Container(
      color: palette.surfaceVariant,
      child: Center(
        child: Icon(
          Icons.tv_rounded,
          size: 32,
          color: palette.textSecondary,
        ),
      ),
    );
  }

  void _play(BuildContext context) {
    context.push<void>(downloadedPlayLocation(media));
  }
}
