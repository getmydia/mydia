import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';
import 'poster_frame.dart';
import 'progress_overlay.dart';

/// A portrait poster for the library grid and list.
///
/// The depth treatment (resting shadow, hover accent, reduced motion, ambient
/// backdrop) lives in [PosterFrame]; this widget contributes only the artwork,
/// the placeholder, its overlays, and the title beneath.
class MediaPoster extends StatelessWidget {
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
            ],
          ],
        ),
      ),
    );
  }
}
