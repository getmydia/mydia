import 'package:flutter/material.dart';

import '../../../core/theme/depth_tokens.dart';
import '../../../core/ui/reduced_motion.dart';
import 'glass_pointer.dart';

/// Press and hover feel for a Liquid Glass control: the glass swells and
/// stretches toward the finger, the specular follows the pointer, and on
/// macOS hovering brightens the rim. With Reduce Motion the press is only
/// a brightness change.
///
/// Passive: it listens without competing in the gesture arena, so the
/// button inside keeps its tap, focus and semantics.
class GlassInteraction extends StatefulWidget {
  const GlassInteraction({
    super.key,
    this.enabled = true,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  @override
  State<GlassInteraction> createState() => _GlassInteractionState();
}

class _GlassInteractionState extends State<GlassInteraction> {
  bool _pressed = false;
  bool _hovered = false;
  Offset? _light;

  @override
  void didUpdateWidget(GlassInteraction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _pressed = false;
      _hovered = false;
      _light = null;
    }
  }

  Offset? _fraction(Offset local) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return null;
    return Offset(
      (local.dx / box.size.width).clamp(0.0, 1.0),
      (local.dy / box.size.height).clamp(0.0, 1.0),
    );
  }

  void _down(PointerDownEvent e) => setState(() {
        _pressed = true;
        _light = _fraction(e.localPosition);
      });

  void _move(PointerMoveEvent e) {
    if (!_pressed) return;
    setState(() => _light = _fraction(e.localPosition));
  }

  void _up() => setState(() {
        _pressed = false;
        _light = null;
      });

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final reduce = ReducedMotion.of(context);
    final light = reduce ? null : _light;
    final stretch = (light == null || !_pressed)
        ? Offset.zero
        : (light - const Offset(0.5, 0.5)) * DepthTokens.liquidPressStretch;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: AnimatedScale(
          scale: _pressed && !reduce ? DepthTokens.liquidPressScale : 1.0,
          duration: reduce ? Duration.zero : DepthTokens.liquidPressDuration,
          curve: DepthTokens.liquidPressCurve,
          child: Transform.translate(
            offset: stretch,
            child: GlassPointer(
              light: light,
              hovered: _hovered,
              pressed: _pressed,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
