import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/cache/poster_cache_manager.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/depth_tokens.dart';
import '../../core/ui/reduced_motion.dart';
import 'ambient_backdrop_provider.dart';
import 'progress_overlay.dart';

class MediaPoster extends ConsumerStatefulWidget {
  final String? posterUrl;
  final String title;
  final double? progressPercentage;
  final bool isFavorite;
  final VoidCallback? onTap;
  final bool showTitle;

  const MediaPoster({
    super.key,
    this.posterUrl,
    required this.title,
    this.progressPercentage,
    this.isFavorite = false,
    this.onTap,
    this.showTitle = true,
  });

  @override
  ConsumerState<MediaPoster> createState() => _MediaPosterState();
}

class _MediaPosterState extends ConsumerState<MediaPoster> {
  bool _isHovered = false;

  void _handleHoverEnter() {
    setState(() => _isHovered = true);
    // Drive the ambient backdrop to this poster's artwork so the real-blur
    // chrome tints with it (R5/R9). Skipped when there is no artwork.
    final url = widget.posterUrl;
    if (url != null && url.isNotEmpty) {
      publishBackdropHover(ref, BackdropSource(imageUrl: url, id: url));
    }
  }

  void _handleHoverExit() {
    setState(() => _isHovered = false);
    clearBackdropHover(ref);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = context.reduceMotion;
    final deepened = _isHovered && !reduceMotion;

    // One hover target for the whole card, matching the tap target: the
    // GestureDetector below navigates from the title as well as the poster, so
    // the cursor and the shadow accent have to cover both.
    //
    // Tapping opens the title, it does not start playback, so the affordance is
    // a plain click cursor — no play glyph.
    return MouseRegion(
      cursor:
          widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => _handleHoverEnter(),
      onExit: (_) => _handleHoverExit(),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Solid, always-elevated poster (R7): a resting token shadow that
            // firms up slightly on hover — no lift, no scale (R11). Under
            // reduced motion the hover accent collapses and the resting shadow
            // stays.
            Expanded(
              child: AnimatedContainer(
                duration:
                    reduceMotion ? Duration.zero : DepthTokens.motionMedium,
                curve: DepthTokens.curveStandard,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: deepened
                      ? DepthTokens.posterHover
                      : DepthTokens.posterResting,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    children: [
                      SizedBox.expand(
                        child: widget.posterUrl != null
                            ? CachedNetworkImage(
                                imageUrl: widget.posterUrl!,
                                fit: BoxFit.cover,
                                cacheManager: PosterCacheManager(),
                                placeholder: (context, url) => Container(
                                  color: AppColors.surfaceVariant,
                                  child: const Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                ),
                                errorWidget: (context, url, error) => Container(
                                  color: AppColors.surfaceVariant,
                                  child: const Icon(
                                    Icons.movie,
                                    size: 48,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              )
                            : Container(
                                color: AppColors.surfaceVariant,
                                child: const Icon(
                                  Icons.movie,
                                  size: 48,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                      ),
                      if (widget.progressPercentage != null &&
                          widget.progressPercentage! > 0)
                        ProgressOverlay(percentage: widget.progressPercentage!),
                      if (widget.isFavorite)
                        const Positioned(
                          top: 8,
                          right: 8,
                          child: Icon(
                            Icons.favorite,
                            color: Colors.red,
                            size: 20,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (widget.showTitle) ...[
              const SizedBox(height: 8),
              Text(
                widget.title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
