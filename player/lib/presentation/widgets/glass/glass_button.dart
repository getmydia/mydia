import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/liquid_glass/liquid_glass_support.dart';
import '../glass_surface.dart';
import 'glass_interaction.dart';

/// A text button floating over content (the home hero's secondary action) on
/// iOS and macOS: a neutral glass capsule with a white label and the Liquid
/// Glass press feel. Elsewhere it is the [OutlinedButton] the call site used
/// before.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = 48,
    this.buttonKey,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;

  /// Keys the tappable widget on both paths.
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    if (!LiquidGlassSupport.platformEligible) {
      final style = OutlinedButton.styleFrom(minimumSize: Size(0, height));
      return icon == null
          ? OutlinedButton(
              key: buttonKey,
              onPressed: onPressed,
              style: style,
              child: Text(label),
            )
          : OutlinedButton.icon(
              key: buttonKey,
              onPressed: onPressed,
              style: style,
              icon: Icon(icon),
              label: Text(label),
            );
    }
    final radius = BorderRadius.circular(height / 2);
    return GlassInteraction(
      enabled: onPressed != null,
      child: GlassSurface.control(
        borderRadius: radius,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: buttonKey,
            onTap: onPressed,
            borderRadius: radius,
            splashFactory: NoSplash.splashFactory,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: height),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 22, color: Colors.white),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      label,
                      style: const TextStyle(
                        fontFamily: AppTheme.displayFamily,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
