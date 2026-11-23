import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/liquid_glass/glass_style.dart';
import '../../../core/theme/liquid_glass/liquid_geometry.dart';
import '../../../core/theme/palette.dart';
import '../../../core/theme/surface_roles.dart';
import '../controls/press_scale.dart';
import '../focus_emphasis.dart';
import '../glass_surface.dart';
import 'glass_hit_target.dart';
import 'glass_interaction.dart';

/// A text button floating over content (the home hero's secondary action) on
/// Liquid Glass: a neutral glass capsule with a white label and the Liquid
/// Glass press feel. Elsewhere it is the [OutlinedButton] the call site used
/// before.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height,
    this.buttonKey,
    this.grouped = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  /// The control's height. Unset, it is the Frosted secondary button's 40 and
  /// the kit's 34 pt Medium button on Liquid Glass; an explicit value wins on both.
  final double? height;

  /// Keys the tappable widget on both paths.
  final Key? buttonKey;

  /// Shares the enclosing `BackdropGroup`'s blur pass (glass path only).
  final bool grouped;

  static const double _frostedHitTarget = 48;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    if (!GlassStyle.of(context)) {
      final roles = context.surfaceRoles;
      final style = OutlinedButton.styleFrom(
        minimumSize: Size(0, height ?? AppTheme.secondaryButtonHeight),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        // The hairline holds in every state: FocusEmphasis below draws the
        // television focus ring, and the theme's focus border would sit
        // inside it as a second one.
        side: BorderSide(color: roles.hairlineStrong),
      );
      final button = icon == null
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
      final visual = FocusEmphasis(
        size: FocusSize.control,
        borderRadius: BorderRadius.circular(roles.radiusControl),
        child: PressScale(enabled: onPressed != null, child: button),
      );
      // The visual is 40 high; touch keeps a 48 high target, and a tap in
      // the margin above or below fires the press too.
      // Padding rather than a centring wrapper: it passes the parent's width
      // constraints through, so a button under a tight width still fills it.
      final margin = math.max(
        0.0,
        (_frostedHitTarget - (height ?? AppTheme.secondaryButtonHeight)) / 2,
      );
      final target = Padding(
        padding: EdgeInsets.symmetric(vertical: margin),
        child: visual,
      );
      if (onPressed == null) return target;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: onPressed,
        child: target,
      );
    }
    final glassHeight = height ?? LiquidGeometry.buttonMedium;
    final radius = BorderRadius.circular(glassHeight / 2);
    final foreground = onPressed == null
        ? context.palette.textDisabled
        : Colors.white;
    final glass = GlassInteraction(
      enabled: onPressed != null,
      child: GlassSurface.control(
        borderRadius: radius,
        grouped: grouped,
        child: Semantics(
          button: true,
          enabled: onPressed != null,
          label: label,
          excludeSemantics: true,
          onTap: onPressed,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: buttonKey,
              onTap: onPressed,
              borderRadius: radius,
              splashFactory: NoSplash.splashFactory,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: glassHeight),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (icon != null) ...[
                        Icon(icon, size: 22, color: foreground),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        label,
                        style: TextStyle(
                          fontFamily: AppTheme.displayFamily,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: foreground,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return GlassHitTarget(
      height: glassHeight,
      onTap: onPressed,
      child: FocusEmphasis(borderRadius: radius, child: glass),
    );
  }
}
