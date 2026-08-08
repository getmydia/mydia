import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';
import 'poster_frame.dart';
import 'progress_overlay.dart';
import 'rating_badge.dart';

/// A portrait poster for the library grid and list.
///
/// The depth treatment (resting shadow, hover accent, reduced motion, ambient
/// backdrop) lives in [PosterFrame]; this widget contributes only the artwork,
/// the placeholder, its overlays, and the title beneath.
class MediaPoster extends StatelessWidget {
  final String? posterUrl;
  final String title;
  final String? subtitle;
  final double? progressPercentage;

  /// TMDB's score on a 0 to 10 scale. Null, or `0.0` for a title nobody has
  /// voted on, renders no chip at all.
  final double? rating;
  final bool isFavorite;
  final VoidCallback? onTap;
  final bool showTitle;

  const MediaPoster({
    super.key,
    this.posterUrl,
    required this.title,
    this.subtitle,
    this.progressPercentage,
    this.rating,
    this.isFavorite = false,
    this.onTap,
    this.showTitle = true,
  });

  static const Widget _placeholder = ColoredBox(
    color: AppColors.surfaceVariant,
    child: Icon(
      Icons.movie,
      size: 48,
      color: AppColors.textSecondary,
    ),
  );

  static const Widget _loadingPlaceholder = ColoredBox(
    color: AppColors.surfaceVariant,
    child: Center(child: CircularProgressIndicator()),
  );

  @override
  Widget build(BuildContext context) {
    final progress = progressPercentage;
    final rating = this.rating;

    // The cursor sits out here rather than on the PosterFrame, because the
    // GestureDetector's tap target includes the title label and the affordance
    // has to cover everything that responds to a click. PosterFrame sets no
    // cursor of its own, so this one wins inside it too.
    //
    // A click cursor and nothing more: tapping opens the title, it does not
    // start playback, so there is no play glyph and no hoverOverlay here.
    return MouseRegion(
      cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: PosterFrame(
                imageUrl: posterUrl,
                placeholder: _placeholder,
                loadingPlaceholder: _loadingPlaceholder,
                overlays: [
                  if (progress != null && progress > 0)
                    ProgressOverlay(percentage: progress),
                  // TMDB reports 0.0 for a title nobody has voted on, so 0 and
                  // null both mean "no rating" and the overlay is omitted
                  // rather than rendered empty. RatingBadge's doc explains why
                  // the widget cannot hide itself.
                  if (rating != null && rating > 0)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: RatingBadge(rating: rating),
                    ),
                  if (isFavorite)
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
            if (showTitle) ...[
              const SizedBox(height: 8),
              Text(
                title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
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
          ],
        ),
      ),
    );
  }
}
