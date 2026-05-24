import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/cache/poster_cache_manager.dart';
import '../../core/layout/breakpoints.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/media_file.dart';
import 'progress_overlay.dart';
import 'quality_badge.dart';

class MediaCard extends StatefulWidget {
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
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  bool _isPressed = false;

  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _elevationAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.04).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic),
    );
    _elevationAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _handleHoverEnter() {
    setState(() => _isHovered = true);
    _animationController.forward();
  }

  void _handleHoverExit() {
    setState(() => _isHovered = false);
    _animationController.reverse();
  }

  void _handleTapDown(TapDownDetails details) {
    setState(() => _isPressed = true);
  }

  void _handleTapUp(TapUpDetails details) {
    setState(() => _isPressed = false);
    widget.onTap?.call();
  }

  void _handleTapCancel() {
    setState(() => _isPressed = false);
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

    return MouseRegion(
      onEnter: (_) => _handleHoverEnter(),
      onExit: (_) => _handleHoverExit(),
      child: GestureDetector(
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        child: AnimatedBuilder(
          animation: _animationController,
          builder: (context, child) {
            return Transform.scale(
              scale: _isPressed ? 0.96 : _scaleAnimation.value,
              child: child,
            );
          },
          child: SizedBox(
            width: cardWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Poster container
                AnimatedBuilder(
                  animation: _animationController,
                  builder: (context, child) {
                    return Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: 0.15 + (_elevationAnimation.value * 0.2),
                            ),
                            blurRadius: 8 + (_elevationAnimation.value * 12),
                            offset: Offset(
                              0,
                              4 + (_elevationAnimation.value * 4),
                            ),
                          ),
                        ],
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
                          ProgressOverlay(
                              percentage: widget.progressPercentage!),

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

                        // Hover overlay with glassmorphism
                        AnimatedOpacity(
                          opacity: _isHovered ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 2, sigmaY: 2),
                              child: Container(
                                width: cardWidth,
                                height: cardHeight,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.black.withValues(alpha: 0.3),
                                      Colors.black.withValues(alpha: 0.6),
                                    ],
                                  ),
                                ),
                                child: Center(
                                  child: Container(
                                    width: 56,
                                    height: 56,
                                    decoration: BoxDecoration(
                                      color: AppColors.primary,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: AppColors.primary
                                              .withValues(alpha: 0.4),
                                          blurRadius: 16,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.play_arrow_rounded,
                                      size: 32,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
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
