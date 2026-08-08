import 'package:flutter/material.dart';

/// The TMDB rating pill drawn over poster artwork.
///
/// Mirrors the treatment `movie_detail_screen.dart`'s `_buildStatBadge` uses
/// for ratings, so a rating reads the same wherever the app shows one. The
/// black scrim is deliberate rather than a palette surface: this chip sits
/// directly on artwork and has to stay legible over a bright poster.
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
          const Icon(Icons.star_rounded, size: 14, color: Colors.amber),
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
