import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/cache/poster_cache_manager.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/player/input_capabilities.dart';
import '../../../core/player/platform_features.dart';
import '../../../core/theme/depth_tokens.dart';
import '../glass_surface.dart';
import '../shimmer_card.dart';
import 'chrome_panel.dart';
import 'chrome_top_bar.dart';
import 'control_button.dart';
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
  bool _expanded = false;
  bool _hovering = false;
  bool _focused = false;
  bool _lastReportedEngaged = false;

  bool get _engaged => _expanded || _hovering || _focused;

  void _syncEngagement() {
    final engaged = _engaged;
    if (engaged == _lastReportedEngaged) return;
    _lastReportedEngaged = engaged;
    widget.onEngagedChanged(engaged);
  }

  void _setExpanded(bool value) {
    if (_expanded == value) return;
    setState(() => _expanded = value);
    _syncEngagement();
  }

  void _setHovering(bool value) {
    if (_hovering == value) return;
    setState(() => _hovering = value);
    _syncEngagement();
  }

  void _setFocused(bool value) {
    if (_focused == value) return;
    setState(() => _focused = value);
    _syncEngagement();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        right: PanelMetrics.cornerInsetRight,
        bottom: widget.metrics.cornerInsetBottom,
      ),
      child: Align(
        alignment: Alignment.bottomRight,
        child: FocusScope(
          onFocusChange: _setFocused,
          child: MouseRegion(
            onEnter: (_) => _setHovering(true),
            onExit: (_) => _setHovering(false),
            child: AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : DepthTokens.motionFast,
              curve: DepthTokens.curveStandard,
              alignment: Alignment.bottomRight,
              child: _expanded ? _buildCard(context) : _buildPill(context),
            ),
          ),
        ),
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
      onTap: () => _setExpanded(true),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CountdownRing(countdown: widget.countdown),
          const SizedBox(width: 8),
          _FocusableTap(
            onTap: () => _setExpanded(true),
            child: Text(widget.target.pillLabel),
          ),
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

  Widget _buildCard(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    // Clamp both branches: below a 32px-wide viewport `width - 32` would
    // otherwise go negative, which trips BoxConstraints' non-negative
    // assert downstream — the same class of bug already guarded in
    // `PanelMetrics.resolve` (chrome_panel.dart).
    final cardWidth = width < 600
        ? math.max(0.0, width - 32)
        : (width - 48).clamp(0.0, 320.0);
    final still = widget.target.thumbnailUrl;
    final glassText = TextStyle(
        color: Colors.white.withValues(alpha: .80),
        shadows: GlassPill.textShadow);
    return GestureDetector(
      key: UpNextPrompt.cardKey,
      behavior: HitTestBehavior.opaque,
      onTap: () => _setExpanded(false),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: cardWidth.toDouble()),
        child: GlassSurface.playerChrome(
          tier: widget.tier,
          borderRadius: const BorderRadius.all(
              Radius.circular(DepthTokens.radiusPlayerPanel)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(widget.target.eyebrow.toUpperCase(),
                            style: glassText.copyWith(
                                fontSize: 9,
                                letterSpacing: 1.2,
                                fontWeight: FontWeight.w500)),
                        _CountdownRing(countdown: widget.countdown),
                      ]),
                  const SizedBox(height: 11),
                  Row(children: [
                    if (still != null) ...[
                      _CardStill(url: still),
                      const SizedBox(width: 10)
                    ],
                    Expanded(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(widget.target.episodeCode,
                              style: glassText.copyWith(fontSize: 9.5)),
                          const SizedBox(height: 2),
                          Text(widget.target.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white.withValues(alpha: .94),
                                  shadows: GlassPill.textShadow)),
                        ])),
                  ]),
                  const SizedBox(height: 11),
                  Row(children: [
                    Expanded(
                      child: _FocusableTap(
                        key: UpNextPrompt.playKey,
                        onTap: widget.onPlayNow,
                        // The fill is white, so a same-alpha ring painted at
                        // its own edge would be invisible against it. A 2px
                        // ring inset keeps the ring on the dark chrome behind
                        // the pill, where it actually shows.
                        ringPadding: 2,
                        borderRadius: const BorderRadius.all(
                          Radius.circular(DepthTokens.radiusPlayerPill + 2),
                        ),
                        child: Container(
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .92),
                            borderRadius: const BorderRadius.all(
                              Radius.circular(DepthTokens.radiusPlayerPill),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.play_arrow_rounded,
                                  size: 16, color: Color(0xFF0B0B0C)),
                              SizedBox(width: 4),
                              Text('Play now',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF0B0B0C))),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ControlButton(
                        key: UpNextPrompt.dismissKey,
                        icon: Icons.close_rounded,
                        size: 32,
                        iconSize: 18,
                        tooltip: 'Dismiss',
                        onTap: widget.onDismiss),
                  ]),
                ]),
          ),
        ),
      ),
    );
  }
}

class _CardStill extends StatelessWidget {
  const _CardStill({required this.url});
  final String url;
  @override
  Widget build(BuildContext context) => ClipRRect(
        key: UpNextPrompt.stillKey,
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
            width: 80,
            height: 45,
            // `episode_rail_card.dart` already caches this exact episode
            // still under the same cache manager, so reusing it here is a
            // cache hit rather than a second download.
            child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                cacheManager: EpisodeThumbnailCacheManager(),
                placeholder: (_, __) =>
                    const ShimmerCard(width: 80, height: 45),
                errorWidget: (_, __, ___) =>
                    ColoredBox(color: Colors.white.withValues(alpha: .06)))),
      );
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
    final Widget region = _FocusableTap(
      onTap: onTap,
      constraints: const BoxConstraints(
        minWidth: UpNextPrompt.segmentHitWidth,
      ),
      child: Center(widthFactor: 1, child: child),
    );
    final message = tooltip;
    if (message == null) return region;
    return Tooltip(message: message, child: region);
  }
}

/// A keyboard-activatable, focus-ringed tap target for the prompt's
/// irregularly-shaped controls — the pill's label and segments, and the
/// card's "Play now" button — none of which are the circular hit target
/// [ControlButton] draws.
///
/// Mirrors [ControlButton]'s treatment: a 2px white ring at
/// [ControlButton.focusRingOpacity], activated by Enter or Space. Built on
/// [FocusableActionDetector] rather than a hand-rolled `Focus` +
/// `onKeyEvent`, which lets this drop the separate `MouseRegion` its
/// predecessor needed for the pointer cursor.
class _FocusableTap extends StatefulWidget {
  const _FocusableTap({
    super.key,
    required this.onTap,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
    this.ringPadding = 0,
    this.constraints,
  });

  final VoidCallback onTap;
  final Widget child;
  final BorderRadius borderRadius;

  /// Gap between the ring and [child], so a ring drawn flush against a
  /// light-filled child (the card's white "Play now" pill) doesn't paint
  /// over its own fill.
  final double ringPadding;
  final BoxConstraints? constraints;

  @override
  State<_FocusableTap> createState() => _FocusableTapState();
}

class _FocusableTapState extends State<_FocusableTap> {
  bool _focused = false;

  static const _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
  };

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (value) {
        if (_focused == value) return;
        setState(() => _focused = value);
      },
      shortcuts: _shortcuts,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: EdgeInsets.all(widget.ringPadding),
          constraints: widget.constraints,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            border: _focused
                ? Border.all(
                    color: Colors.white
                        .withValues(alpha: ControlButton.focusRingOpacity),
                    width: 2,
                  )
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
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
