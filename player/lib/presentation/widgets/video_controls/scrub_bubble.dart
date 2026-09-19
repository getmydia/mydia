import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/cache/poster_cache_manager.dart';
import '../../../core/player/playback_time_format.dart';
import '../../../core/player/scrub_controller.dart';
import '../../../core/player/scrub_thumbnails.dart';
import '../../../core/player/thumbnail_service.dart';

/// Where the bubble's left edge goes so it sits centred over the cursor
/// without leaving the track's horizontal bounds.
double scrubBubbleLeft({
  required double trackWidth,
  required double bubbleWidth,
  required double fraction,
}) {
  final maxLeft = math.max(0.0, trackWidth - bubbleWidth);
  return (trackWidth * fraction - bubbleWidth / 2)
      .clamp(0.0, maxLeft)
      .toDouble();
}

/// `+02:30` or `-00:40`: how far the cursor is from where the scrub began.
String formatScrubDelta(Duration delta) =>
    '${delta.isNegative ? '-' : '+'}${formatPlaybackTime(delta.abs())}';

/// The label that floats above a D-pad scrub cursor: the target time, how
/// far that is from where the scrub started, and a trickplay frame when the
/// file has sprites.
class ScrubBubble extends StatelessWidget {
  const ScrubBubble({
    super.key,
    required this.target,
    required this.delta,
    this.thumbnail,
  });

  /// Fixed, so [scrubBubbleLeft] can clamp it without measuring: the
  /// generator's 160px frame plus padding.
  static const double width = 176;
  static const double frameWidth = 160;
  static const double frameHeight = 90;

  static const Key targetKey = Key('scrub-bubble-target');
  static const Key deltaKey = Key('scrub-bubble-delta');
  static const Key frameKey = Key('scrub-bubble-frame');

  final Duration target;
  final Duration delta;
  final Widget? thumbnail;

  @override
  Widget build(BuildContext context) {
    final frame = thumbnail;
    return Container(
      width: width,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        // Foreground, not decoration: a decoration border insets the child,
        // which would shrink the 160px frame to 158.
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (frame != null) ...[
            ClipRRect(
              key: frameKey,
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: frameWidth,
                height: frameHeight,
                child: frame,
              ),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            formatPlaybackTime(target),
            key: targetKey,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            formatScrubDelta(delta),
            key: deltaKey,
            // Opaque grey, not translucent white: a translucent foreground
            // composites with the fill and measures lower contrast than it
            // looks.
            style: const TextStyle(
              color: Color(0xFFBDBDBD),
              fontSize: 14,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// One frame cut out of a trickplay sprite sheet.
///
/// The sheet is a single image holding every frame, so a frame is shown by
/// offsetting the whole sheet behind a clip the size of one cue. The
/// `OverflowBox` lets the sheet lay out at its natural size inside that clip,
/// and the `FittedBox` scales the cue to whatever box the caller gives it.
class SpriteFrame extends StatelessWidget {
  const SpriteFrame({
    super.key,
    required this.cue,
    required this.spriteUrl,
    required this.headers,
  });

  final ThumbnailCue cue;
  final String spriteUrl;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final w = cue.width.toDouble();
    final h = cue.height.toDouble();
    const blank = ColoredBox(color: Color(0xFF212121));
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: w,
        height: h,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: w,
            minHeight: h,
            maxWidth: w,
            maxHeight: h,
            child: Transform.translate(
              offset: Offset(-cue.x.toDouble(), -cue.y.toDouble()),
              child: CachedNetworkImage(
                imageUrl: spriteUrl,
                cacheManager: SeekSpriteCacheManager(),
                httpHeaders: headers,
                fit: BoxFit.none,
                alignment: Alignment.topLeft,
                placeholder: (context, url) => blank,
                errorWidget: (context, url, error) => blank,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pins a [ScrubBubble] above [child], the progress bar, while a scrub is
/// active.
///
/// The bubble cannot be a child of the bar: the chrome panel is a
/// `GlassSurface`, whose `ClipRRect` cuts off anything drawn above its own
/// bounds. It is drawn in the overlay through an [OverlayPortal], and a
/// [CompositedTransformFollower] keeps it attached to the bar wherever the
/// panel is laid out.
class ScrubBubbleAnchor extends StatefulWidget {
  const ScrubBubbleAnchor({
    super.key,
    required this.scrub,
    required this.child,
    this.thumbnails,
  });

  /// Space between the bubble and the top of the bar.
  static const double gap = 12;

  final ScrubController scrub;
  final ScrubThumbnails? thumbnails;
  final Widget child;

  @override
  State<ScrubBubbleAnchor> createState() => _ScrubBubbleAnchorState();
}

class _ScrubBubbleAnchorState extends State<ScrubBubbleAnchor> {
  final LayerLink _link = LayerLink();
  final OverlayPortalController _portal = OverlayPortalController();

  /// The bar's width at its last layout. Read when the bubble builds, which
  /// is always after a key press, long after the bar was first laid out.
  double _trackWidth = 0;

  @override
  void initState() {
    super.initState();
    // Always shown; the overlay child draws nothing while no scrub is active.
    _portal.show();
    widget.scrub.addListener(_onScrubChanged);
  }

  @override
  void didUpdateWidget(ScrubBubbleAnchor old) {
    super.didUpdateWidget(old);
    if (!identical(old.scrub, widget.scrub)) {
      old.scrub.removeListener(_onScrubChanged);
      widget.scrub.addListener(_onScrubChanged);
    }
  }

  @override
  void dispose() {
    widget.scrub.removeListener(_onScrubChanged);
    super.dispose();
  }

  void _onScrubChanged() {
    if (widget.scrub.active) widget.thumbnails?.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _buildBubble,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _trackWidth = constraints.maxWidth;
          return CompositedTransformTarget(link: _link, child: widget.child);
        },
      ),
    );
  }

  Widget _buildBubble(BuildContext context) {
    final thumbnails = widget.thumbnails;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.scrub, thumbnails]),
      builder: (context, _) {
        final scrub = widget.scrub;
        final cursor = scrub.cursor;
        final origin = scrub.origin;
        final fraction = scrub.displayFraction;
        if (cursor == null || origin == null || fraction == null) {
          return const SizedBox.shrink();
        }

        final cue = thumbnails?.cueAt(cursor);
        final left = scrubBubbleLeft(
          trackWidth: _trackWidth,
          bubbleWidth: ScrubBubble.width,
          fraction: fraction,
        );
        return Align(
          alignment: Alignment.topLeft,
          child: IgnorePointer(
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topLeft,
              followerAnchor: Alignment.bottomLeft,
              offset: Offset(left, -ScrubBubbleAnchor.gap),
              child: ScrubBubble(
                target: cursor,
                delta: cursor - origin,
                thumbnail: cue == null || thumbnails == null
                    ? null
                    : SpriteFrame(
                        cue: cue,
                        spriteUrl: thumbnails.spriteUrl,
                        headers: thumbnails.imageHeaders,
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}
