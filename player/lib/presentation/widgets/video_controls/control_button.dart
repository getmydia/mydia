import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../../core/theme/depth_tokens.dart';
import '../focus_highlight.dart';

/// A playback-chrome control button.
///
/// Sizes are set explicitly by callers from the spec's sizing table rather than
/// via named constructors, so the optical relationship between the transport
/// glyphs stays visible at the call site.
///
/// Carries no per-glyph shadow: the glass panel behind it provides legibility.
/// Stamped shadows were a workaround for chrome that had no backing surface,
/// and they are a direct cause of a muddy appearance.
class ControlButton extends StatefulWidget {
  /// The icon to display. Must be from the `_rounded` family.
  final IconData icon;

  /// Called when the button is tapped, or activated via Enter/Space while
  /// focused.
  final VoidCallback? onTap;

  /// Hit-target size (width and height).
  final double size;

  /// Glyph size.
  final double iconSize;

  /// Optional tooltip text.
  final String? tooltip;

  /// Whether the button responds to input.
  final bool enabled;

  /// Optional externally-owned focus node.
  ///
  /// The player owns one for the play/pause button so it can move focus onto a
  /// real control when it reveals the OSD. Without that, revealing the chrome
  /// leaves focus on the screen's own node, which paints no ring, and the
  /// viewer cannot tell what a subsequent OK would do.
  final FocusNode? focusNode;

  /// Whether a change of [icon] cross-fades instead of snapping.
  ///
  /// The animation is deliberately *inside* this widget rather than around it.
  /// An `AnimatedSwitcher` wrapped around a `ControlButton` mounts two of them
  /// for the length of the transition, and since this widget's focus node may
  /// be supplied by a caller ([focusNode]), that would attach one node to two
  /// live widgets at once — which the focus system does not support. Animating
  /// the glyph keeps a single owner for the node and cross-fades identically.
  final bool animateIcon;

  const ControlButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 44,
    this.iconSize = 24,
    this.tooltip,
    this.enabled = true,
    this.focusNode,
    this.animateIcon = false,
  });

  /// Glyph opacity at rest.
  static const double restOpacity = 0.92;

  /// Glyph opacity when disabled.
  static const double disabledOpacity = 0.30;

  /// Alpha of the circular backdrop shown on hover.
  static const double hoverBackdropOpacity = 0.08;

  /// Alpha of the 2px focus ring.
  static const double focusRingOpacity = 0.60;

  @override
  State<ControlButton> createState() => _ControlButtonState();
}

class _ControlButtonState extends State<ControlButton> {
  /// Owned directly (rather than left for `FocusHighlight` to auto-create) so
  /// this state can request focus and expose the node to tests via
  /// `Focus.focusNode`. `FocusableActionDetector` installs a `Focus`
  /// internally, so that finder keeps working.
  final FocusNode _focusNode = FocusNode(debugLabel: 'ControlButton');

  bool _hovering = false;
  bool _pressed = false;

  bool get _interactive => widget.enabled && widget.onTap != null;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final noMotion = MediaQuery.disableAnimationsOf(context);
    final hoverTarget = (_hovering && _interactive) ? 1.0 : 0.0;

    final Widget core = SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedScale(
        scale: _pressed && !noMotion ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: DepthTokens.curveStandard,
        child: FocusHighlight(
          focusNode: widget.focusNode ?? _focusNode,
          onActivate: _interactive ? widget.onTap : null,
          circular: true,
          ringWidth: 2,
          ringOpacity: ControlButton.focusRingOpacity,
          // A single implicit-animation owner for both the hover backdrop
          // and the glyph opacity: they're the same hover transition and
          // must move together, not just start together. Driving them from
          // one interpolated `t` also avoids the closure-capture hazard a
          // separate `Builder` introduced previously (see git history).
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: hoverTarget),
            duration: DepthTokens.motionFast,
            curve: DepthTokens.curveStandard,
            builder: (context, t, _) {
              final glyphOpacity = widget.enabled
                  ? lerpDouble(ControlButton.restOpacity, 1.0, t)!
                  : ControlButton.disabledOpacity;
              final backdropAlpha = ControlButton.hoverBackdropOpacity * t;
              final glyph = Icon(
                widget.icon,
                size: widget.iconSize,
                color: Colors.white.withValues(alpha: glyphOpacity),
              );
              return DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: backdropAlpha),
                ),
                child: Center(
                  child: widget.animateIcon
                      ? AnimatedSwitcher(
                          duration: const Duration(milliseconds: 120),
                          // Neither glyph overshoots full size. A
                          // ScaleTransition reads the animation the switcher
                          // hands its builder: 0 -> 1 for the incoming glyph
                          // and 1 -> 0 for the outgoing one, because
                          // AnimatedSwitcher reverses the outgoing entry's
                          // controller and eases it back through
                          // `switchOutCurve`. Both curves therefore only have
                          // to stay inside [0, 1], and the pair reads as the
                          // same scale-and-fade the wrapping switcher
                          // produced: grow in, shrink out. Reading the
                          // outgoing animation through ReverseAnimation
                          // instead would run its scale backwards, blowing the
                          // departing glyph up to full size on the way out;
                          // that is not what shipped.
                          //
                          // Linear is `AnimatedSwitcher`'s default, and it is
                          // named here rather than left implicit only to say
                          // that it is deliberate: the wrapper this replaces
                          // set no curves either, so keeping the default is
                          // what stops this refactor from subtly restyling a
                          // transition the viewer already knows.
                          switchInCurve: Curves.linear,
                          switchOutCurve: Curves.linear,
                          transitionBuilder: (child, animation) =>
                              ScaleTransition(
                            scale: animation,
                            child: FadeTransition(
                              opacity: animation,
                              child: child,
                            ),
                          ),
                          // Keyed on the glyph, so a change of icon — and only
                          // a change of icon — triggers the cross-fade.
                          child: KeyedSubtree(
                            key: ValueKey<IconData>(widget.icon),
                            child: glyph,
                          ),
                        )
                      : glyph,
                ),
              );
            },
          ),
        ),
      ),
    );

    final Widget button = MouseRegion(
      cursor:
          _interactive ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _interactive ? (_) => setState(() => _pressed = true) : null,
        onTapCancel:
            _interactive ? () => setState(() => _pressed = false) : null,
        onTap: _interactive
            ? () {
                setState(() => _pressed = false);
                widget.onTap!();
              }
            : null,
        child: core,
      ),
    );

    final tooltip = widget.tooltip;
    if (tooltip != null) {
      return Tooltip(message: tooltip, child: button);
    }
    return button;
  }
}
