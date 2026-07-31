import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/depth_tokens.dart';

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

  const ControlButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 44,
    this.iconSize = 24,
    this.tooltip,
    this.enabled = true,
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
  /// Owned directly (rather than left for `Focus` to auto-create) so this
  /// state can request focus, listen for focus changes without a `Builder`
  /// indirection, and expose the node to tests via `Focus.focusNode`.
  final FocusNode _focusNode = FocusNode(debugLabel: 'ControlButton');

  bool _hovering = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _interactive => widget.enabled && widget.onTap != null;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!mounted) return;
    setState(() => _focused = _focusNode.hasFocus);
  }

  /// Wires Enter/Space activation for keyboard users. A focus ring that
  /// nothing responds to is a defect, not polish: without this, a
  /// keyboard-only user can tab to the button and see the ring, but never
  /// activate it.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_interactive || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      widget.onTap!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
        child: Focus(
          focusNode: _focusNode,
          canRequestFocus: _interactive,
          onKeyEvent: _handleKeyEvent,
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
              return DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: backdropAlpha),
                  border: _focused
                      ? Border.all(
                          color: Colors.white.withValues(
                            alpha: ControlButton.focusRingOpacity,
                          ),
                          width: 2,
                        )
                      : null,
                ),
                child: Center(
                  child: Icon(
                    widget.icon,
                    size: widget.iconSize,
                    color: Colors.white.withValues(alpha: glyphOpacity),
                  ),
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
