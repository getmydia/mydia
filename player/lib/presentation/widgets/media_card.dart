import 'package:flutter/material.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/depth_tokens.dart';
import '../../domain/models/media_file.dart';
import 'glass_surface.dart';
import 'poster_frame.dart';
import 'progress_overlay.dart';
import 'quality_badge.dart';

/// A portrait poster card for the horizontal content rails.
///
/// The depth treatment lives in [PosterFrame]; this widget contributes the
/// artwork, the quality badges, its own hover treatment, and the title and
/// subtitle beneath. Unlike [MediaPoster] it carries explicit dimensions,
/// because rails lay out along a fixed-height axis.
class MediaCard extends StatelessWidget {
  final String? posterUrl;
  final String title;
  final String? subtitle;
  final double? progressPercentage;
  final VoidCallback? onTap;
  final double? width;
  final double? height;
  final List<MediaFile>? files;

  /// If true, uses responsive sizing based on screen width.
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

  /// Get responsive card dimensions for the current context.
  static CardSize getResponsiveSize(BuildContext context) =>
      Breakpoints.getCardSize(context);

  // Default dimensions for non-responsive mode.
  static const double _defaultWidth = 130;
  static const double _defaultHeight = 195;

  Widget _buildPlaceholder() {
    return ColoredBox(
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

  /// A faux-glass darkening scrim with no live blur, so per-card scrolling
  /// content never creates a [BackdropFilter] pass (R8).
  Widget _buildHoverOverlay() {
    return GlassSurface.faux(
      showRim: false,
      borderRadius: BorderRadius.circular(DepthTokens.radiusPoster),
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0x4D000000), // black @ 0.3
          Color(0x99000000), // black @ 0.6
        ],
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
                color: AppColors.primary.withValues(alpha: 0.4),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final cardFiles = files;
    final quality = cardFiles != null && cardFiles.isNotEmpty
        ? getBestQuality(cardFiles)
        : const MediaQuality();

    // Calculate dimensions: use explicit, responsive, or defaults.
    final double cardWidth;
    final double cardHeight;
    if (width != null && height != null) {
      cardWidth = width!;
      cardHeight = height!;
    } else if (responsive) {
      final size = Breakpoints.getCardSize(context);
      cardWidth = width ?? size.width;
      cardHeight = height ?? size.height;
    } else {
      cardWidth = width ?? _defaultWidth;
      cardHeight = height ?? _defaultHeight;
    }

    final progress = progressPercentage;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: cardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: cardWidth,
              height: cardHeight,
              child: PosterFrame(
                imageUrl: posterUrl,
                placeholder: _buildPlaceholder(),
                hoverOverlay: _buildHoverOverlay(),
                overlays: [
                  if (progress != null && progress > 0)
                    ProgressOverlay(percentage: progress),
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
            const SizedBox(height: 10),
            Text(
              title,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
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
    );
  }
}
