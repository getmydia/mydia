import 'package:flutter/material.dart';

/// The kebab that opens a poster card's secondary menu.
///
/// A [PosterFrame] overlay, so it positions itself the way that widget's
/// `overlays` contract requires. Bottom-right rather than top-right, because
/// `PosterBadgeCorner` already owns the top-right for watch and quality
/// badges, and inset far enough up to clear a `ProgressOverlay` sitting on the
/// bottom edge.
///
/// This exists because the menu it opens is otherwise reachable only by
/// long-press or right-click, neither of which a card advertises. Continue
/// Watching is the surface that needs it: "Remove from Continue Watching" is
/// the one action on these cards a viewer goes looking for, and an affordance
/// nobody can see is not one.
///
/// Deliberately not a [PopupMenuButton] of its own, unlike
/// `EpisodeRailCard._buildWatchedMenu` which it is styled after. It calls the
/// same `onContextMenu` callback the long-press already routes through, so the
/// two affordances cannot drift into offering different things.
class PosterMenuButton extends StatelessWidget {
  /// Opens the menu. The card passes its own context so the menu anchors to
  /// the card rather than to this button.
  final VoidCallback onPressed;

  /// Named for the surface, so screen readers do not just say "button".
  final String tooltip;

  const PosterMenuButton({
    super.key,
    required this.onPressed,
    this.tooltip = 'More actions',
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 6,
      bottom: 10,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(10),
        ),
        child: IconButton(
          icon: const Icon(
            Icons.more_vert_rounded,
            color: Colors.white,
            size: 20,
          ),
          tooltip: tooltip,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(),
          visualDensity: VisualDensity.compact,
          style: const ButtonStyle(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: onPressed,
        ),
      ),
    );
  }
}
