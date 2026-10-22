import 'package:flutter/material.dart';

import '../../../core/theme/liquid_glass/liquid_geometry.dart';

/// Pads a glass control shorter than the 44 pt minimum out to a 44 pt
/// tappable area, keeping the width constraints as they were. The glass keeps
/// its kit height; a tap in the margin above or below it fires [onTap] too.
/// The inner control owns the semantics, so the margin adds none.
class GlassHitTarget extends StatelessWidget {
  const GlassHitTarget({
    super.key,
    required this.height,
    required this.onTap,
    required this.child,
  });

  /// The glass's own height.
  final double height;

  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final margin = (LiquidGeometry.minHitTarget - height) / 2;
    if (margin <= 0) return child;
    final padded = Padding(
      padding: EdgeInsets.symmetric(vertical: margin),
      child: child,
    );
    if (onTap == null) return padded;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: onTap,
      child: padded,
    );
  }
}
