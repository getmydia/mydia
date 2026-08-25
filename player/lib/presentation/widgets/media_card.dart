import 'package:flutter/material.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/depth_tokens.dart';
import '../../domain/models/media_file.dart';
import '../../domain/models/watch_status.dart';
import 'focus_highlight.dart';
import 'poster_badge_corner.dart';
import 'poster_frame.dart';
import 'poster_menu_button.dart';
import 'progress_overlay.dart';
import 'quality_badge.dart';
import 'watch_indicator.dart';

/// What tapping a [MediaCard] does.
///
/// The card's affordance follows from this: an [open] card offers a click
/// cursor and nothing else, a [play] card draws an always-visible badge so a
/// touch user can see the tap will launch playback. Required rather than
/// defaulted, because the promise and the behavior drifted apart once already.
/// The widget took an opaque `onTap` plus a doc comment claiming it never
/// played, while two of the four home rails handed it a callback that did.
enum MediaCardAction { open, play }

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

  /// Rolled-up watch state. Null renders no indicator.
  final WatchStatus? watchStatus;
  final VoidCallback? onTap;
  final double? width;
  final double? height;
  final List<MediaFile>? files;

  /// What tapping this card does. Drives the affordance, so it is required.
  final MediaCardAction action;

  /// Called on long press and on secondary tap, with a context inside this
  /// card so the menu can anchor to it. Null means the card has no menu.
  final void Function(BuildContext cardContext)? onContextMenu;

  /// Whether to show a persistent kebab that opens the same menu as
  /// [onContextMenu]. Ignored when there is no menu to open.
  ///
  /// Off by default: most rails offer only navigation entries a card's own tap
  /// already reaches, so a visible affordance would be clutter pointing at
  /// nothing new. Continue Watching turns it on, where the menu carries an
  /// action nothing else on the card offers.
  final bool showMenuButton;

  /// If true, uses responsive sizing based on screen width.
  final bool responsive;

  const MediaCard({
    super.key,
    this.posterUrl,
    required this.title,
    this.subtitle,
    this.progressPercentage,
    this.watchStatus,
    this.onTap,
    this.width,
    this.height,
    this.files,
    required this.action,
    this.onContextMenu,
    this.showMenuButton = false,
    this.responsive = false,
  });

  /// Get responsive card dimensions for the current context.
  static CardSize getResponsiveSize(BuildContext context) =>
      Breakpoints.getCardSize(context);

  // Default dimensions for non-responsive mode.
  static const double _defaultWidth = 130;
  static const double _defaultHeight = 195;

  /// Finder handle for the play badge, so tests assert on the badge itself
  /// rather than on whichever glyph happens to be inside it.
  static const playBadgeKey = ValueKey('media-card-play-badge');

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

    final contextMenu = onContextMenu;

    // The tap target wraps the whole card, title and subtitle included. What
    // the tap promises comes from `action`: an opening card offers a click
    // cursor and no glyph, a playing card also carries the badge below.
    //
    // FocusHighlight sits outermost so the ring encloses the poster and its
    // labels together, which is what a viewer scanning a rail with a remote
    // is actually selecting. `borderRadius` uses the shared poster token so
    // the ring traces the same corner radius `PosterFrame` already paints.
    return FocusHighlight(
      onActivate: onTap,
      borderRadius:
          const BorderRadius.all(Radius.circular(DepthTokens.radiusPoster)),
      child: MouseRegion(
        cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          onTap: onTap,
          // Long press for touch, secondary tap for a desktop right-click.
          // Both reach the same menu, the way Infuse exposes the same actions
          // on iOS and on the Mac.
          onLongPress: contextMenu == null ? null : () => contextMenu(context),
          onSecondaryTap:
              contextMenu == null ? null : () => contextMenu(context),
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
                      // `watchStatus` supersedes `progressPercentage` when
                      // both arrive. See the same guard in `MediaPoster` for
                      // why.
                      if (watchStatus == null &&
                          progress != null &&
                          progress > 0)
                        ProgressOverlay(percentage: progress),
                      WatchProgressOverlay(status: watchStatus),
                      if (action == MediaCardAction.play) const _PlayBadge(),
                      PosterBadgeCorner(
                        children: [
                          WatchIndicator(status: watchStatus),
                          if (quality.hasQuality)
                            QualityBadgeRow(
                              badges: quality.toBadges(),
                              spacing: 4.0,
                            ),
                        ],
                      ),
                      // Routed through the same callback as the long-press,
                      // so the button and the gesture can never offer
                      // different menus.
                      if (showMenuButton && contextMenu != null)
                        Builder(
                          builder: (buttonContext) => PosterMenuButton(
                            onPressed: () => contextMenu(buttonContext),
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
      ),
    );
  }
}

/// The touch-visible promise that this card's tap starts playback.
///
/// Always painted rather than revealed on hover, because hover never fires on
/// a phone and the phone is where the ambiguity was reported. Sits inset above
/// [ProgressOverlay]'s 4px bar rather than flush in the corner: every Continue
/// Watching card carries both at once.
class _PlayBadge extends StatelessWidget {
  const _PlayBadge();

  @override
  Widget build(BuildContext context) {
    return const Positioned(
      left: 8,
      bottom: 10,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.primary,
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: EdgeInsets.all(4),
          child: Icon(
            Icons.play_arrow_rounded,
            key: MediaCard.playBadgeKey,
            size: 18,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
