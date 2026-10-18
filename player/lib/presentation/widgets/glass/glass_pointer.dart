import 'package:flutter/widgets.dart';

/// Pointer state for the Liquid Glass surface below it: where the light
/// sits and whether the control is hovered or pressed. Provided by
/// `GlassInteraction`, read by `LiquidGlassFilter`.
class GlassPointer extends InheritedWidget {
  const GlassPointer({
    super.key,
    this.light,
    this.hovered = false,
    this.pressed = false,
    required super.child,
  });

  /// Light position as a fraction of the surface, or null for the resting
  /// light.
  final Offset? light;
  final bool hovered;
  final bool pressed;

  static GlassPointer? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassPointer>();

  @override
  bool updateShouldNotify(GlassPointer oldWidget) =>
      oldWidget.light != light ||
      oldWidget.hovered != hovered ||
      oldWidget.pressed != pressed;
}
