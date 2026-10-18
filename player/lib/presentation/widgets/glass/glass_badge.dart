import 'package:flutter/material.dart';

import '../../../core/theme/liquid_glass/liquid_glass_support.dart';
import '../glass_surface.dart';

/// A small label over artwork ("Next Up · S1 E13") on iOS and macOS: a glass
/// capsule with no press interaction. Elsewhere it paints
/// [fallbackDecoration], the call site's previous look.
class GlassBadge extends StatelessWidget {
  const GlassBadge({
    super.key,
    required this.child,
    required this.padding,
    required this.fallbackDecoration,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Decoration fallbackDecoration;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    if (!LiquidGlassSupport.platformEligible) {
      return DecoratedBox(decoration: fallbackDecoration, child: content);
    }
    return GlassSurface.control(
      borderRadius: BorderRadius.circular(999),
      child: content,
    );
  }
}
