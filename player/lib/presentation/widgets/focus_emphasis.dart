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

class _FocusEmphasisState extends State<FocusEmphasis> {
  bool _focused = false;

  void _onFocusChange(bool focused) {
    if (focused != _focused) setState(() => _focused = focused);
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
      ring =
          RRect.fromRectAndRadius(rect, Radius.circular(rect.shortestSide / 2));
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
        ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 10),
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
