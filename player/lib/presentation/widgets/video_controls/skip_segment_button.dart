import 'package:flutter/material.dart';

import '../../../core/player/platform_features.dart';
import '../../../domain/models/media_segment.dart';
import 'chrome_panel.dart';
import 'chrome_top_bar.dart';

/// Records which segments have already been auto-skipped this playback session.
///
/// Without this, auto-skip makes an intro unwatchable: a viewer who seeks back
/// into it is thrown straight out again with no way to override. Each segment
/// therefore gets exactly one automatic skip per media item, and [reset] runs
/// when the media changes so the next episode starts with a clean record.
///
/// Identity comes from [MediaSegment.key] rather than object equality, so a
/// refetch that rebuilds the segment list does not resurrect a spent skip.
class SegmentSkipTracker {
  final Set<String> _skipped = <String>{};

  /// Whether [segment] may still be skipped automatically.
  bool shouldAutoSkip(MediaSegment segment) => !_skipped.contains(segment.key);

  void markSkipped(MediaSegment segment) => _skipped.add(segment.key);

  /// Forgets every recorded skip. Called on media change.
  void reset() => _skipped.clear();

  /// The segment to auto-skip at [position], or null when none applies.
  ///
  /// Marks the segment as spent before returning it, so this is the whole
  /// once-per-session guard in one place rather than a rule each caller has to
  /// reassemble from [shouldAutoSkip] and [markSkipped]. The position listener
  /// calls it on every tick, which is exactly why the marking has to be
  /// inseparable from the decision.
  MediaSegment? takeAutoSkip(
    Iterable<MediaSegment> segments,
    Duration position,
  ) {
    for (final segment in segments) {
      if (!segment.actionable) continue;
      if (!segment.containsPosition(position)) continue;
      if (!shouldAutoSkip(segment)) continue;
      markSkipped(segment);
      return segment;
    }
    return null;
  }
}

/// A transient "Skip Intro" / "Skip Credits" affordance.
///
/// Renders nothing unless playback is currently inside [segment], so the caller
/// can mount it unconditionally and let position drive visibility. It sits
/// bottom-right above the transport chrome, in the same glass material as the
/// rest of the playback controls.
///
/// The button stays available even for a segment auto-skip has already spent:
/// a viewer who seeks back into the intro on purpose is choosing to watch it,
/// and taking the manual affordance away as well would leave them with nothing.
class SkipSegmentButton extends StatelessWidget {
  const SkipSegmentButton({
    super.key,
    required this.segment,
    required this.position,
    required this.onSkip,
    required this.metrics,
    this.tier,
  });

  /// The segment this button offers to skip.
  final MediaSegment segment;

  /// Current playback position, in real media coordinates.
  final Duration position;

  /// Called with [segment] when the viewer taps. The caller does the seeking;
  /// this widget deliberately holds no player reference.
  final void Function(MediaSegment segment) onSkip;

  /// Corner geometry. Both insets come from here so this widget and
  /// `UpNextPrompt` cannot drift apart; the old private constants cited
  /// `UpNextOverlay`, which was the one widget not following the design
  /// system.
  final PanelMetrics metrics;

  /// Glass tier override, passed through to [GlassPill] so golden tests do not
  /// vary with the host platform.
  final PlayerGlassTier? tier;

  static const Key buttonKey = Key('skip-segment-button');

  @override
  Widget build(BuildContext context) {
    if (!segment.actionable || !segment.containsPosition(position)) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsets.only(
        right: PanelMetrics.cornerInsetRight,
        bottom: metrics.cornerInsetBottom,
      ),
      child: Align(
        alignment: Alignment.bottomRight,
        child: GlassPill(
          key: buttonKey,
          tier: tier,
          onTap: () => onSkip(segment),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.fast_forward_rounded),
              const SizedBox(width: 6),
              Text(segment.label),
            ],
          ),
        ),
      ),
    );
  }
}
