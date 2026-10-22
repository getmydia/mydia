import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/liquid_glass/glass_style.dart';
import '../../core/theme/liquid_glass/liquid_geometry.dart';
import '../../core/theme/palette.dart';
import 'focus_highlight.dart';
import 'glass/glass_interaction.dart';
import 'glass_surface.dart';

/// The detail pages' Play / Resume control: a play icon and a label on a pill.
///
/// Off Liquid Glass it is the design system's white pill and never paints
/// the palette's primary. On Liquid Glass an enabled button is neutral Liquid
/// Glass, the same control material as every other floating button, with a
/// white label; it stands out by size and weight. A null [onPressed] renders the disabled surface and
/// takes no focus, the same as the control it replaced.
class PrimaryPlayButton extends StatefulWidget {
  const PrimaryPlayButton({
    super.key,
    required this.onPressed,
    this.label = 'Play',
    this.iconOnly = false,
    this.grouped = false,
  });

  /// Drop the text for width-bounded layouts. The label stays as the
  /// accessibility name.
  final bool iconOnly;

  final VoidCallback? onPressed;

  /// Shares the enclosing `BackdropGroup`'s blur pass (glass path only).
  final bool grouped;

  /// "Play", or "Resume" when the item has saved progress.
  final String label;

  /// The control's height off Liquid Glass, comfortably above the 48 px touch
  /// target. On it the kit's 50 pt Large button applies.
  static const double height = 48;

  /// Space between the pill and its focus ring.
  static const double ringGap = 3;

  /// Finder handle for the white pill itself.
  static const pillKey = ValueKey('primary-play-pill');

  @override
  State<PrimaryPlayButton> createState() => _PrimaryPlayButtonState();
}

class _PrimaryPlayButtonState extends State<PrimaryPlayButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 100),
    vsync: this,
  );
  late final Animation<double> _scale = Tween<double>(begin: 1.0, end: 0.95)
      .animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  static const _radius =
      BorderRadius.all(Radius.circular(AppTheme.radiusButton));
  static const _ringRadius = BorderRadius.all(
      Radius.circular(AppTheme.radiusButton + PrimaryPlayButton.ringGap));

  bool get _enabled => widget.onPressed != null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final glass = GlassStyle.of(context) && _enabled;
    final foreground = !_enabled
        ? palette.textDisabled
        : (glass ? Colors.white : palette.background);
    final height =
        glass ? LiquidGeometry.buttonLarge : PrimaryPlayButton.height;
    final radius = glass ? BorderRadius.circular(height / 2) : _radius;
    final ringRadius = glass
        ? BorderRadius.circular(height / 2 + PrimaryPlayButton.ringGap)
        : _ringRadius;
    final ink = InkWell(
      borderRadius: radius,
      splashFactory: glass ? NoSplash.splashFactory : null,
      // FocusHighlight above is the single focus stop for this button.
      // InkWell would otherwise register a second, invisible one nested
      // inside it, so a D-pad user would press twice to clear it.
      canRequestFocus: false,
      onTap: widget.onPressed,
      // GlassInteraction supplies the press swell on glass.
      onTapDown: _enabled && !glass ? (_) => _controller.forward() : null,
      onTapUp: _enabled && !glass ? (_) => _controller.reverse() : null,
      onTapCancel: _enabled && !glass ? () => _controller.reverse() : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: height),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: widget.iconOnly ? 11 : 22,
          ),
          child: Semantics(
            label: widget.iconOnly ? widget.label : null,
            excludeSemantics: widget.iconOnly,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.play_arrow_rounded,
                  size: 26,
                  color: foreground,
                ),
                if (!widget.iconOnly) ...[
                  const SizedBox(width: 8),
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontFamily: AppTheme.displayFamily,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: foreground,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    final Widget pill = glass
        ? GlassInteraction(
            child: GlassSurface.control(
              key: PrimaryPlayButton.pillKey,
              borderRadius: radius,
              grouped: widget.grouped,
              child: Material(type: MaterialType.transparency, child: ink),
            ),
          )
        : Material(
            key: PrimaryPlayButton.pillKey,
            color: _enabled ? Colors.white : palette.surfaceVariant,
            borderRadius: radius,
            child: ink,
          );
    return ScaleTransition(
      scale: _scale,
      child: FocusHighlight(
        onActivate: widget.onPressed,
        // A ring in the gap around the pill. Gold off Liquid Glass, where the white
        // fill would hide a white ring; white on glass, where it reads.
        borderRadius: ringRadius,
        ringColor: glass ? Colors.white : palette.primary,
        ringOpacity: 1,
        child: Padding(
          padding: const EdgeInsets.all(PrimaryPlayButton.ringGap),
          child: pill,
        ),
      ),
    );
  }
}
