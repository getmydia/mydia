import 'package:flutter/material.dart';

import '../../core/player/input_capabilities.dart';
import '../../core/theme/palette.dart';

/// The television tier's look for a focused button: it grows, and an accent
/// ring with a soft glow is drawn just outside it.
///
/// A viewer across the room has only this to tell them where they are. The
/// thin ring a button carries elsewhere disappears at that distance, and a
/// white ring on a white Play pill, or on Liquid Glass over bright artwork,
/// disappears up close too. The accent reads on every fill the buttons use.
///
/// Wraps a button whose focus node is inside [child]: it listens for focus
/// anywhere below and takes none of its own, so it adds no focus stop. The
/// ring and glow paint outside [child]'s bounds and the growth is a
/// transform, so the layout around the button does not move.
///
/// Off the television tier it returns [child] untouched: a keyboard or mouse
/// user keeps each button's own focus look.
class FocusEmphasis extends StatefulWidget {
  const FocusEmphasis({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.circular = false,
    this.gap = defaultGap,
  });

  final Widget child;

  /// The button's own corner radius; the ring follows it, widened by [gap].
  final BorderRadius borderRadius;

  /// For round buttons; overrides [borderRadius].
  final bool circular;

  /// Space between the button's edge and the ring.
  final double gap;

  static const double defaultGap = 3;
  static const double scale = 1.07;
  static const double ringWidth = 4;

  /// Finder handles for tests.
  static const scaleKey = ValueKey('focus-emphasis-scale');
  static const ringKey = ValueKey('focus-emphasis-ring');

  @override
  State<FocusEmphasis> createState() => _FocusEmphasisState();
}

/// How far the glow spreads past the ring.
const double _glowBlur = 10;

class _FocusEmphasisState extends State<FocusEmphasis> {
  bool _focused = false;

  void _onFocusChange(bool focused) {
    if (focused == _focused) return;
    setState(() => _focused = focused);
    if (focused) WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  /// Scrolls the whole emphasis into view, not just the button.
  ///
  /// Traversal reveals the focused node's own bounds, so a button entered at
  /// the edge of a scrolled page would have its grown edge, ring and glow
  /// cut off by the viewport. Runs after traversal's own reveal, and moves
  /// nothing when the extra margin is already on screen.
  void _reveal() {
    // Focus may have moved on before this frame ended; revealing the button
    // it left would scroll away from where it went.
    if (!mounted || !_focused) return;
    // A page already scrolling has somewhere to be (picking an episode
    // carries the page back to its hero); a reveal now would cut that short.
    for (var s = Scrollable.maybeOf(context);
        s != null;
        s = Scrollable.maybeOf(s.context)) {
      if (s.position.isScrollingNotifier.value) return;
    }
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final size = box.size;
    final grow = size.longestSide * (FocusEmphasis.scale - 1) / 2;
    final margin =
        widget.gap + FocusEmphasis.ringWidth + _glowBlur + grow.ceilToDouble();
    box.showOnScreen(
      rect: (Offset.zero & size).inflate(margin),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!InputCapabilities.directionalPrimary) return widget.child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _onFocusChange,
      child: AnimatedScale(
        key: FocusEmphasis.scaleKey,
        scale: _focused ? FocusEmphasis.scale : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: CustomPaint(
          key: FocusEmphasis.ringKey,
          // Glow and ring both lie outside the button's bounds, so painting
          // them in front covers none of it.
          foregroundPainter: FocusEmphasisPainter(
            visible: _focused,
            color: context.palette.primary,
            borderRadius: widget.borderRadius,
            circular: widget.circular,
            gap: widget.gap,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Paints [FocusEmphasis]'s ring and the glow around it.
@visibleForTesting
class FocusEmphasisPainter extends CustomPainter {
  FocusEmphasisPainter({
    required this.visible,
    required this.color,
    required this.borderRadius,
    required this.circular,
    required this.gap,
  });

  final bool visible;
  final Color color;
  final BorderRadius borderRadius;
  final bool circular;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible) return;
    final inset = gap + FocusEmphasis.ringWidth / 2;
    final rect = (Offset.zero & size).inflate(inset);
    final RRect ring;
    if (circular) {
      // A circle around the centre even when the bounds are not square, so
      // the ring follows the round control rather than becoming a capsule.
      ring = RRect.fromRectAndRadius(
        Rect.fromCircle(
          center: size.center(Offset.zero),
          radius: size.shortestSide / 2 + inset,
        ),
        Radius.circular(size.shortestSide / 2 + inset),
      );
    } else {
      final r = borderRadius;
      ring = RRect.fromRectAndCorners(
        rect,
        topLeft: r.topLeft + Radius.circular(inset),
        topRight: r.topRight + Radius.circular(inset),
        bottomLeft: r.bottomLeft + Radius.circular(inset),
        bottomRight: r.bottomRight + Radius.circular(inset),
      );
    }
    canvas.drawRRect(
      ring,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = FocusEmphasis.ringWidth * 2
        ..color = color.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.outer, _glowBlur),
    );
    canvas.drawRRect(
      ring,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = FocusEmphasis.ringWidth
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(FocusEmphasisPainter old) =>
      old.visible != visible ||
      old.color != color ||
      old.borderRadius != borderRadius ||
      old.circular != circular ||
      old.gap != gap;
}
