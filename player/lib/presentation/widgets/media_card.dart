import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/cache/poster_cache_manager.dart';
import '../../core/layout/breakpoints.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/depth_tokens.dart';
import '../../core/ui/reduced_motion.dart';
import '../../domain/models/media_file.dart';
import 'ambient_backdrop_provider.dart';
import 'progress_overlay.dart';
import 'quality_badge.dart';

class MediaCard extends ConsumerStatefulWidget {
  final String? posterUrl;
  final String title;
  final String? subtitle;
  final double? progressPercentage;
  final VoidCallback? onTap;
  final double? width;
  final double? height;
  final List<MediaFile>? files;

  /// If true, uses responsive sizing based on screen width
  final bool responsive;

  const MediaCard({
    super.key,
    this.posterUrl,
    required this.title,
    this.subtitle,
    this.progressPercentage,
    this.onTap,
    this.width,
    this.height,
    this.files,
    this.responsive = false,
  });

  /// Get responsive card dimensions for the current context
  static CardSize getResponsiveSize(BuildContext context) =>
      Breakpoints.getCardSize(context);

  @override
  ConsumerState<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends ConsumerState<MediaCard>
    with SingleTickerProviderStateMixin {
  // Drives the gentle hover accent: a slight shadow deepening only — no lift,
  // scale, or sheen (R11).
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: DepthTokens.motionFast,
      vsync: this,
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _handleHoverEnter() {
    _animationController.forward();
    // Drive the ambient backdrop to this poster's artwork so the real-blur
    // chrome tints with it (R5/R9). Skipped when there is no artwork.
    final url = widget.posterUrl;
    if (url != null && url.isNotEmpty) {
      publishBackdropHover(ref, BackdropSource(imageUrl: url, id: url));
    }
  }

  void _handleHoverExit() {
    _animationController.reverse();
    // Revert to the screen's default backdrop.
    clearBackdropHover(ref);
  }

  // Default dimensions for non-responsive mode
  static const double _defaultWidth = 130;
  static const double _defaultHeight = 195;

  @override
  Widget build(BuildContext context) {
    final quality = widget.files != null && widget.files!.isNotEmpty
        ? getBestQuality(widget.files!)
        : const MediaQuality();

    // Calculate dimensions: use explicit, responsive, or defaults
    final double cardWidth;
    final double cardHeight;
    if (widget.width != null && widget.height != null) {
      cardWidth = widget.width!;
      cardHeight = widget.height!;
    } else if (widget.responsive) {
      final size = Breakpoints.getCardSize(context);
      cardWidth = widget.width ?? size.width;
      cardHeight = widget.height ?? size.height;
    } else {
      cardWidth = widget.width ?? _defaultWidth;
      cardHeight = widget.height ?? _defaultHeight;
    }

    // Hover accent (R11): the poster stays put — no lift, no scale jump, no
    // sheen. Its resting shadow only firms up slightly on hover. Collapses to
    // no change under reduced motion.
    final reduceMotion = context.reduceMotion;

    return MouseRegion(
      // Tapping a card opens the title, it does not start playback, so the
      // affordance is a plain click cursor — no play glyph.
      cursor:
          widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => _handleHoverEnter(),
      onExit: (_) => _handleHoverExit(),
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: cardWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Poster container — a solid, always-elevated object with a
              // resting token shadow that deepens slightly on hover (R7).
              AnimatedBuilder(
                animation: _animationController,
                builder: (context, child) {
                  final t = reduceMotion ? 0.0 : _animationController.value;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: BoxShadow.lerpList(
                        DepthTokens.posterResting,
                        DepthTokens.posterHover,
                        t,
                      ),
                    ),
                    child: child,
                  );
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    children: [
                      // Poster image
                      SizedBox(
                        width: cardWidth,
                        height: cardHeight,
                        child: widget.posterUrl != null
                            ? CachedNetworkImage(
                                imageUrl: widget.posterUrl!,
                                fit: BoxFit.cover,
                                cacheManager: PosterCacheManager(),
                                placeholder: (context, url) =>
                                    _buildPlaceholder(),
                                errorWidget: (context, url, error) =>
                                    _buildPlaceholder(),
                              )
                            : _buildPlaceholder(),
                      ),

                      // Progress overlay at bottom
                      if (widget.progressPercentage != null &&
                          widget.progressPercentage! > 0)
                        ProgressOverlay(percentage: widget.progressPercentage!),

                      // Quality badges at top-right
                      if (quality.hasQuality)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: QualityBadgeRow(
                            badges: quality.toBadges(),
                            spacing: 4.0,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Title
              Text(
                widget.title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),

              // Subtitle
              if (widget.subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  widget.subtitle!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: AppColors.surfaceVariant,
      child: Center(
        child: Icon(
          Icons.movie_rounded,
          size: 40,
          color: AppColors.textSecondary.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}
