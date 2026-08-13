import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';
import '../../domain/models/watch_status.dart';
import 'progress_overlay.dart';

/// The single owner of how watch state looks.
///
/// Every poster surface renders this rather than deciding for itself. The
/// alternative was letting seven call sites each combine `watched`,
/// `percentage`, and `unwatchedEpisodeCount` on their own, and
/// `poster_frame.dart` documents where that ends up: the poster depth
/// contract was hand-rolled three times, drifted once, and `SearchResultCard`
/// broke it again during the rollout of the very widget built to prevent it.
///
/// The states are ordered and mutually exclusive:
///
///  * watched, draw nothing;
///  * a show or season with episodes left, draw the count;
///  * a leaf part-played, draw the bar via [WatchProgressOverlay];
///  * anything else, draw the dot.
///
/// A part-played poster deliberately shows no dot. The bar already says "not
/// finished", so a dot beside it would be saying it twice.
///
/// This widget draws only the corner mark. The bar lives in
/// [WatchProgressOverlay] because it sits at the bottom of the overlay stack
/// while the mark sits in the top-right corner, and a single widget cannot be
/// in both places. Both read the same getters on [WatchStatus], so the rule
/// stays in one file.
class WatchIndicator extends StatelessWidget {
  /// Null whenever the viewer is unauthenticated, or the query did not ask
  /// for the field. Both draw nothing.
  final WatchStatus? status;

  const WatchIndicator({super.key, required this.status});

  /// Lets tests assert on the dot without depending on its shape.
  static const Key dotKey = Key('watch-indicator-dot');

  static const double _dotDiameter = 10.0;

  @override
  Widget build(BuildContext context) {
    final status = this.status;

    if (status == null) return const SizedBox.shrink();

    if (status.isUnwatchedContainer) {
      return _CountPill(count: status.unwatchedEpisodeCount!);
    }

    if (status.isUntouched) {
      return Container(
        key: dotKey,
        width: _dotDiameter,
        height: _dotDiameter,
        decoration: const BoxDecoration(
          color: AppColors.primary,
          shape: BoxShape.circle,
        ),
      );
    }

    return const SizedBox.shrink();
  }
}

class _CountPill extends StatelessWidget {
  final int count;

  const _CountPill({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      // No cap. A show with 137 unwatched episodes says 137, because "99+"
      // would hide exactly the case the badge is most useful for.
      child: Text(
        '$count',
        style: const TextStyle(
          color: AppColors.surfaceVariant,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
      ),
    );
  }
}

/// The bottom progress bar half of the rule owned by [WatchIndicator].
///
/// Goes into a [PosterFrame]'s overlay list, where [ProgressOverlay]
/// positions itself along the bottom edge.
class WatchProgressOverlay extends StatelessWidget {
  final WatchStatus? status;

  const WatchProgressOverlay({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final status = this.status;

    if (status == null || !status.isInProgress) return const SizedBox.shrink();

    return ProgressOverlay(percentage: status.percentage!);
  }
}
