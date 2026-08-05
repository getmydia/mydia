import 'package:flutter/material.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/media_file.dart';
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

    // A click cursor and nothing more: tapping a card opens the title, it does
    // not start playback, so there is no play glyph and no hoverOverlay here.
    // The cursor wraps the whole tap target, title and subtitle included.
    return MouseRegion(
      cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
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
      ),
    );
  }
}
