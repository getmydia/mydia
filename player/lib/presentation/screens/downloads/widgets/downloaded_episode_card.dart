import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/cache/poster_cache_manager.dart';
import '../../../../core/layout/breakpoints.dart';
import '../../../../core/playback/playback_progress_providers.dart';
import '../../../../core/theme/colors.dart';
import '../../../../domain/models/download.dart';
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
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.primary,
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
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
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
              child: thumbnailUrl != null && thumbnailUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: thumbnailUrl,
                      fit: BoxFit.cover,
                      cacheManager: EpisodeThumbnailCacheManager(),
                      placeholder: (context, url) =>
                          Container(color: AppColors.surfaceVariant),
                      errorWidget: (context, url, error) => _buildPlaceholder(),
                    )
                  : _buildPlaceholder(),
            ),
            if (media.quality.isNotEmpty)
              Positioned(
                right: 6,
                bottom: 10,
                child: QualityBadge.resolution(media.quality),
              ),
            _buildResumeBar(ref),
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
  Widget _buildResumeBar(WidgetRef ref) {
    final store = ref.watch(playbackProgressStoreProvider).value;
    if (store == null) return const SizedBox.shrink();

    final progress = store.get(media.mediaId);
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
        decoration: const BoxDecoration(color: AppColors.surfaceVariant),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: fraction,
          child: const DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.only(
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
        tooltip: 'Episode actions',
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
          const PopupMenuItem(
            value: 'play',
            child: Row(
              children: [
                Icon(Icons.play_arrow_rounded, size: 18),
                SizedBox(width: 12),
                Text('Play'),
              ],
            ),
          ),
          const PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                Icon(
                  Icons.delete_outline_rounded,
                  size: 18,
                  color: AppColors.error,
                ),
                SizedBox(width: 12),
                Text('Delete', style: TextStyle(color: AppColors.error)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: AppColors.surfaceVariant,
      child: const Center(
        child: Icon(
          Icons.tv_rounded,
          size: 32,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  /// `fileId=offline` is what tells the player screen to resolve the local
  /// file instead of asking the server for a stream.
  void _play(BuildContext context) {
    final season = media.seasonNumber;
    context.push(
      '/player/episode/${media.mediaId}'
      '?fileId=offline'
      '&title=${Uri.encodeComponent(media.title)}'
      '&showId=$showId'
      '${season != null ? '&seasonNumber=$season' : ''}',
    );
  }
}
