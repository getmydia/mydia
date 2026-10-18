import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/depth_tokens.dart';
import '../../../core/theme/liquid_glass/liquid_glass_support.dart';
import '../../../core/theme/palette.dart';
import '../glass_surface.dart';
import 'glass_interaction.dart';

/// A floating icon button over content (back, cast) on iOS and macOS: a
/// glass circle with the Liquid Glass press feel. Elsewhere it is the plain
/// [IconButton] the call site used before.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color,
  });

  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (!LiquidGlassSupport.platformEligible) {
      return IconButton(
        icon: icon,
        onPressed: onPressed,
        tooltip: tooltip,
        color: color,
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.hasBoundedHeight
          ? math.min(
              DepthTokens.liquidIconButtonSize,
              constraints.maxHeight - 2 * DepthTokens.liquidIconButtonInset,
            )
          : DepthTokens.liquidIconButtonSize;
      return GlassInteraction(
        enabled: onPressed != null,
        child: SizedBox.square(
          dimension: size,
          child: GlassSurface.control(
            borderRadius: BorderRadius.circular(size / 2),
            child: Material(
              type: MaterialType.transparency,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: IconButton(
                icon: icon,
                onPressed: onPressed,
                tooltip: tooltip,
                color: color ?? context.palette.textPrimary,
                padding: EdgeInsets.zero,
                style: IconButton.styleFrom(
                  splashFactory: NoSplash.splashFactory,
                  minimumSize: Size.square(size),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}
