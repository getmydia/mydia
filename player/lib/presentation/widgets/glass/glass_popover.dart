import 'package:flutter/material.dart';

import '../../../core/theme/depth_tokens.dart';
import '../../../core/theme/liquid_glass/liquid_glass_support.dart';
import '../../../core/theme/palette.dart';
import '../glass_surface.dart';

/// The popover's card: modal glass on iOS and macOS, the elevated
/// `surfaceVariant` Material elsewhere (the source picker's previous look).
class GlassPopoverSurface extends StatelessWidget {
  const GlassPopoverSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!LiquidGlassSupport.platformEligible) {
      return Material(
        color: context.palette.surfaceVariant,
        elevation: 8,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: child,
      );
    }
    return GlassSurface.modal(
      borderRadius: BorderRadius.circular(DepthTokens.liquidPopoverRadius),
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}
