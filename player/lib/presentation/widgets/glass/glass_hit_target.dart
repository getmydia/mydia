import 'package:flutter/material.dart';

import '../../../core/theme/liquid_glass/liquid_geometry.dart';

/// Holds a glass control at its kit [height] inside a tappable area of at
/// least 44 pt, keeping the width constraints as they were. A tap in the
/// margin above or below the glass fires [onTap] too.
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
    final target = LayoutBuilder(
      builder: (context, incoming) {
        // The glass is exactly [height] whatever height the parent forces
        // (a chip row's SizedBox, say); a tight width still reaches it.
        final glass = ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: incoming.hasTightWidth ? incoming.maxWidth : 0,
            maxWidth: incoming.maxWidth,
            minHeight: height,
            maxHeight: height,
          ),
          child: child,
        );
        return ConstrainedBox(
          constraints:
              const BoxConstraints(minHeight: LiquidGeometry.minHitTarget),
          child: Center(widthFactor: 1, heightFactor: 1, child: glass),
        );
      },
    );
    if (onTap == null) return target;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: onTap,
      child: target,
    );
  }
}
