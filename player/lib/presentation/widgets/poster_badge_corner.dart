import 'package:flutter/material.dart';

/// The single owner of a poster's top-right corner.
///
/// Before this existed, `MediaPoster` hand-positioned the favourite heart at
/// `top: 8, right: 8` and `MediaCard` hand-positioned `QualityBadgeRow` at the
/// same coordinates. Adding a third occupant meant either overlapping one of
/// them or a third hand-rolled `Positioned`, so the corner became a widget.
///
/// Order is the caller's, and the convention is that the watch indicator
/// leads: it is the primary signal, and it reads first in a left-to-right
/// scan.
///
/// Children that render nothing are dropped rather than spaced around, so a
/// `SizedBox.shrink()` from [WatchIndicator] does not leave a gap where a
/// badge used to be.
class PosterBadgeCorner extends StatelessWidget {
  final List<Widget> children;
  final double spacing;

  const PosterBadgeCorner({
    super.key,
    required this.children,
    this.spacing = 4.0,
  });

  @override
  Widget build(BuildContext context) {
    final visible = children
        .where((child) => child is! SizedBox || child.width != 0)
        .toList();

    if (visible.isEmpty) return const SizedBox.shrink();

    return Positioned(
      top: 8,
      right: 8,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < visible.length; i++) ...[
            if (i > 0) SizedBox(width: spacing),
            visible[i],
          ],
        ],
      ),
    );
  }
}
