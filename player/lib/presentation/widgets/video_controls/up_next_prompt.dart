import 'package:flutter/material.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/player/input_capabilities.dart';
import '../../../core/player/platform_features.dart';
import 'chrome_panel.dart';
import 'chrome_top_bar.dart';
import 'up_next_countdown.dart';
import 'up_next_policy.dart';

/// The next-episode prompt.
///
/// Two states in one widget: a resting [GlassPill] and, in Task 7, an
/// expanded card. The pill is deliberately the same object
/// `SkipSegmentButton` just vacated in the same corner — credits start, the
/// skip pill appears, then this takes its place. One shape, one grammar.
///
/// Holds no `Player` reference and does not own the countdown; both belong to
/// `player_screen`, which is what lets every case here be a plain widget test.
class UpNextPrompt extends StatefulWidget {
  const UpNextPrompt({
    super.key,
    required this.target,
    required this.countdown,
    required this.metrics,
    required this.onPlayNow,
    required this.onDismiss,
    required this.onEngagedChanged,
    this.tier,
  });

  final UpNextTarget target;
  final UpNextCountdown countdown;
  final PanelMetrics metrics;
  final VoidCallback onPlayNow;
  final VoidCallback onDismiss;

  /// Fired with true whenever the viewer is demonstrably attending to this
  /// widget — hovering, focused, or expanded. `player_screen` holds the
  /// countdown while it is true, so reaching for a control is itself enough
  /// to stop the clock.
  final ValueChanged<bool> onEngagedChanged;

  final PlayerGlassTier? tier;

  static const Key pillKey = Key('up-next-pill');
  static const Key cardKey = Key('up-next-card');
  static const Key stillKey = Key('up-next-still');

  /// The play control, and the dismiss control.
  ///
  /// Deliberately reused across both states: only one state is mounted at a
  /// time, so a test — and a screen reader — asks for "the dismiss" without
  /// caring whether the prompt is resting or expanded. Task 7 puts these same
  /// keys on the card's controls.
  static const Key playKey = Key('up-next-play');
  static const Key dismissKey = Key('up-next-dismiss');

  /// Minimum width for the two interactive segments of the resting pill.
  static const double segmentHitWidth = 44.0;

  @override
  State<UpNextPrompt> createState() => _UpNextPromptState();
}

class _UpNextPromptState extends State<UpNextPrompt> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        right: PanelMetrics.cornerInsetRight,
        bottom: widget.metrics.cornerInsetBottom,
      ),
      child: Align(
        alignment: Alignment.bottomRight,
        child: _buildPill(context),
      ),
    );
  }

  Widget _buildPill(BuildContext context) {
    final touch = InputCapabilities.touchPrimary;

    // Below the mobile breakpoint the Play segment sheds its word and keeps
    // the glyph. Two labelled segments plus the countdown label do not fit
    // beside a 360px viewport's other chrome, and the glyph carries the
    // meaning on its own where the word does not fit.
    final compact = MediaQuery.sizeOf(context).width < Breakpoints.mobile;

    return GlassPill(
      key: UpNextPrompt.pillKey,
      tier: widget.tier,
      height: touch ? 44 : GlassPill.defaultHeight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CountdownRing(countdown: widget.countdown),
          const SizedBox(width: 8),
          Text(widget.target.pillLabel),
          const _PillDivider(),
          _PillSegment(
            key: UpNextPrompt.playKey,
            onTap: widget.onPlayNow,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.play_arrow_rounded, size: 16),
                if (!compact) ...[
                  const SizedBox(width: 4),
                  const Text('Play'),
                ],
              ],
            ),
          ),
          const _PillDivider(),
          _PillSegment(
            key: UpNextPrompt.dismissKey,
            onTap: widget.onDismiss,
            tooltip: 'Dismiss',
            child: const Icon(Icons.close_rounded, size: 16),
          ),
        ],
      ),
    );
  }
}

/// A 1px hairline between pill segments.
class _PillDivider extends StatelessWidget {
  const _PillDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 14,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      color: Colors.white.withValues(alpha: 0.20),
    );
  }
}

/// One tappable region of the resting pill, padded out to
/// [UpNextPrompt.segmentHitWidth] so a finger cannot miss it or catch its
/// neighbour.
class _PillSegment extends StatelessWidget {
  const _PillSegment({
    super.key,
    required this.child,
    required this.onTap,
    this.tooltip,
  });

  final Widget child;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final Widget region = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: UpNextPrompt.segmentHitWidth,
          ),
          child: Center(widthFactor: 1, child: child),
        ),
      ),
    );
    final message = tooltip;
    if (message == null) return region;
    return Tooltip(message: message, child: region);
  }
}

/// The draining ring.
///
/// Reads [UpNextCountdown.fraction] and nothing else, so it never learns the
/// total duration. That is what removes the old `value: seconds / 10`
/// hardcode structurally rather than merely correcting the divisor.
///
/// White, not the brand amber: the player chrome carries no hue anywhere, and
/// a coloured ring would make this widget the one exception all over again.
class _CountdownRing extends StatelessWidget {
  const _CountdownRing({required this.countdown});

  final UpNextCountdown countdown;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: countdown,
      builder: (context, _) {
        return SizedBox(
          width: 14,
          height: 14,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: countdown.fraction),
            duration: const Duration(milliseconds: 950),
            curve: Curves.linear,
            builder: (context, value, __) => CircularProgressIndicator(
              value: value,
              strokeWidth: 2,
              backgroundColor: Colors.white.withValues(alpha: 0.22),
              valueColor: AlwaysStoppedAnimation<Color>(
                Colors.white.withValues(alpha: 0.92),
              ),
            ),
          ),
        );
      },
    );
  }
}
