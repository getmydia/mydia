import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/cache/poster_cache_manager.dart';
import '../../core/layout/breakpoints.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/episode.dart';
import '../screens/show/season_episodes_controller.dart';
import 'episode_download_button.dart';

/// A self-contained landscape (16:9) episode card for the horizontal episodes
/// rail: a thumbnail with inline progress/watched overlays, the episode code +
/// title beneath, and corner action overlays (download + watched-status menu).
///
/// Progress and watched state are read only from [Episode.progress] with
/// null-safe access — `progress` is nullable and absent for never-played
/// episodes, and recomputing completion from raw player duration is a known
/// defect during HLS transcode. No duration math happens here.
///
/// Episodes without a playable file render dimmed with an "unavailable" badge
/// and are not tappable.
class EpisodeRailCard extends ConsumerStatefulWidget {
  final Episode episode;
  final String showTitle;
  final String? showId;
  final String? showPosterUrl;
  final bool selected;

  /// Invoked when a playable card is tapped. Ignored (and not wired) when the
  /// episode has no file.
  final VoidCallback? onTap;

  /// Finder handle for the hover preview of the selection ring.
  static const selectionPreviewKey = ValueKey('episode-card-selection-preview');

  const EpisodeRailCard({
    super.key,
    required this.episode,
    required this.showTitle,
    this.showId,
    this.showPosterUrl,
    this.selected = false,
    this.onTap,
  });

  @override
  ConsumerState<EpisodeRailCard> createState() => _EpisodeRailCardState();
}

class _EpisodeRailCardState extends ConsumerState<EpisodeRailCard> {
  bool _isHovered = false;

  Episode get _episode => widget.episode;

  @override
  Widget build(BuildContext context) {
    final cardSize = Breakpoints.getEpisodeCardSize(context);
    final content = _buildContent(context, cardSize);

    if (!_episode.hasFile) {
      // No playable file: dimmed and non-interactive (no tap, no hover-play).
      return SizedBox(
        width: cardSize.width,
        child: Opacity(opacity: 0.5, child: content),
      );
    }

    return SizedBox(
      width: cardSize.width,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: content,
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, CardSize cardSize) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildThumbnail(context, cardSize),
        const SizedBox(height: 8),
        Text(
          _episode.episodeCode,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          _episode.title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildThumbnail(BuildContext context, CardSize cardSize) {
    return Container(
      key: const ValueKey('episode-card-border'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: widget.selected ? AppColors.primary : Colors.transparent,
          width: 2,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: cardSize.width,
          height: cardSize.height,
          child: Stack(
            children: [
              // Thumbnail image (16:9 fills the card).
              Positioned.fill(
                child: _episode.thumbnailUrl != null
                    ? CachedNetworkImage(
                        imageUrl: _episode.thumbnailUrl!,
                        fit: BoxFit.cover,
                        cacheManager: EpisodeThumbnailCacheManager(),
                        placeholder: (context, url) => Container(
                          color: AppColors.surfaceVariant,
                        ),
                        errorWidget: (context, url, error) =>
                            _buildPlaceholder(),
                      )
                    : _buildPlaceholder(),
              ),

              // Hover preview of the selection ring. The tap selects this
              // episode into the hero rather than playing it, so a play glyph
              // here would promise something the tap does not do. The ring
              // previews what the tap will actually leave behind.
              if (!widget.selected)
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      key: EpisodeRailCard.selectionPreviewKey,
                      opacity: _isHovered ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: AppColors.primary.withValues(alpha: 0.6),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              // "Unavailable" badge for episodes with no playable file.
              if (!_episode.hasFile)
                const Positioned.fill(
                  child: Center(
                    child: Icon(
                      Icons.cloud_off_rounded,
                      size: 28,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),

              // Progress bar pinned to the bottom edge.
              if ((_episode.progress?.percentage ?? 0) > 0)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 4,
                    decoration: const BoxDecoration(
                      color: AppColors.surfaceVariant,
                    ),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor:
                          (_episode.progress!.percentage / 100).clamp(0.0, 1.0),
                      child: Container(
                        decoration: const BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.only(
                            topRight: Radius.circular(2),
                            bottomRight: Radius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              // Watched checkmark (top-left, so it never collides with the
              // top-right action overlay).
              if (_episode.progress?.watched == true)
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: AppColors.success,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
                ),

              // Action overlay (top-right): download + watched-status menu, on a
              // dark scrim pill for contrast against the thumbnail.
              Positioned(
                top: 4,
                right: 4,
                child: _buildActions(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    // The watched menu renders independently of download support (e.g. Flutter
    // web, where downloads are unavailable) as long as we know which
    // season-scoped controller to dispatch to.
    final showWatchedMenu = widget.showId != null;

    final actions = <Widget>[
      EpisodeDownloadButton(
        episode: _episode,
        showTitle: widget.showTitle,
        showId: widget.showId,
        showPosterUrl: widget.showPosterUrl,
      ),
      if (showWatchedMenu) _buildWatchedMenu(context),
    ];

    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: actions,
      ),
    );
  }

  Widget _buildWatchedMenu(BuildContext context) {
    final watched = _episode.progress?.watched ?? false;

    return PopupMenuButton<String>(
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
      onSelected: _handleWatchedAction,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: watched ? 'unwatched' : 'watched',
          child: Row(
            children: [
              Icon(
                watched
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                size: 18,
              ),
              const SizedBox(width: 12),
              Text(watched ? 'Mark unwatched' : 'Mark watched'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'this_and_previous',
          child: Row(
            children: [
              Icon(Icons.playlist_add_check_rounded, size: 18),
              SizedBox(width: 12),
              Text('Mark this and previous watched'),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _handleWatchedAction(String value) async {
    final showId = widget.showId;
    if (showId == null) return;

    final controller = ref.read(
      seasonEpisodesControllerProvider(
        showId: showId,
        seasonNumber: _episode.seasonNumber,
      ).notifier,
    );

    try {
      switch (value) {
        case 'watched':
          await controller.markEpisodeWatched(_episode);
          break;
        case 'unwatched':
          await controller.markEpisodeUnwatched(_episode);
          break;
        case 'this_and_previous':
          await controller.markThisAndPreviousWatched(_episode);
          break;
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not update watched status'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
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
}
