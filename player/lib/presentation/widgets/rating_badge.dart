import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';

/// The TMDB rating pill drawn over poster artwork.
///
/// Structurally this is the same chip as `_buildStatBadge` in
/// `series_downloads_screen.dart`: the same padding, scrim, radius and row
/// layout. The black scrim is deliberate rather than a palette surface,
/// because this chip sits directly on artwork and has to stay legible over a
/// bright poster. Note that the movie detail screen renders ratings
/// differently, as a plain unscrimmed row (`_buildRatingLine`), since it has a
/// solid background to sit on.
///
/// The star takes `AppColors.primary` rather than a literal amber so it
/// matches the rating star on the movie detail screen (`_buildRatingLine`).
///
/// Takes a non-nullable [rating] on purpose. TMDB reports `0.0` for a title
/// nobody has voted on and the server passes `vote_average` through unchanged,
/// so `0.0` and "no rating" arrive indistinguishable and both must render
/// nothing at all. That rule cannot live in here: `PosterFrame` requires every
/// entry in its `overlays` list to position itself, and its stack is
/// `StackFit.expand`, so a `SizedBox.shrink()` returned from [build] would
/// inflate to cover the whole poster instead of disappearing. Callers omit the
/// overlay entirely instead.
class RatingBadge extends StatelessWidget {
  /// The score on TMDB's 0 to 10 scale. Rendered to one decimal place.
  final double rating;

  const RatingBadge({
    super.key,
    required this.rating,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 14, color: AppColors.primary),
          const SizedBox(width: 4),
          Text(
            rating.toStringAsFixed(1),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
