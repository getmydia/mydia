import 'package:flutter/material.dart';

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

  /// Called when the button is tapped.
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

  @override
  State<ControlButton> createState() => _ControlButtonState();
}

class _ControlButtonState extends State<ControlButton> {
  bool _hovering = false;
  bool _pressed = false;

  bool get _interactive => widget.enabled && widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    final noMotion = MediaQuery.disableAnimationsOf(context);

    final opacity = !widget.enabled
        ? ControlButton.disabledOpacity
        : _hovering && _interactive
            ? 1.0
            : ControlButton.restOpacity;

    // `core` is assigned exactly once and never reassigned. The `Builder`
    // below closes over it; Dart closures capture variables (not values), so
    // if this were reassigned after the closure's creation — e.g. by naming
    // it `button` and later doing `button = MouseRegion(...)` — the closure
    // would observe the *later* value and return a subtree containing
    // itself, an infinite mounting loop. Keeping `core` immutable avoids that
    // trap.
    final Widget core = SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedScale(
        scale: _pressed && !noMotion ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: DepthTokens.curveStandard,
        child: AnimatedContainer(
          duration: DepthTokens.motionFast,
          curve: DepthTokens.curveStandard,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hovering && _interactive
                ? Colors.white
                    .withValues(alpha: ControlButton.hoverBackdropOpacity)
                : Colors.transparent,
          ),
          child: Center(
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: Colors.white.withValues(alpha: opacity),
            ),
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
        child: Focus(
          canRequestFocus: _interactive,
          child: Builder(
            builder: (context) {
              final focused = Focus.of(context).hasFocus;
              return DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: focused
                      ? Border.all(
                          color: Colors.white.withValues(alpha: 0.60),
                          width: 2,
                        )
                      : null,
                ),
                child: core,
              );
            },
          ),
        ),
      ),
    );

    final tooltip = widget.tooltip;
    if (tooltip != null) {
      return Tooltip(message: tooltip, child: button);
    }
    return button;
  }
}
