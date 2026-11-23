import 'package:material_ui/material_ui.dart';

import '../../../core/theme/liquid_glass/glass_style.dart';
import '../../../core/theme/liquid_glass/liquid_geometry.dart';
import '../../../core/theme/palette.dart';
import '../../../core/theme/surface_roles.dart';
import '../controls/press_scale.dart';
import '../focus_emphasis.dart';
import '../glass_surface.dart';
import 'glass_hit_target.dart';
import 'glass_interaction.dart';

/// A toolbar chip (sort, filter) on Liquid Glass: a glass capsule, white
/// prominent glass when selected. Elsewhere it is the [ChoiceChip] (or
/// [FilterChip] with [multiSelect]) the row used before.
///
/// Put a row of these in a `BackdropGroup`: the chips pass `grouped: true`
/// so they share one backdrop pass.
class GlassChip extends StatelessWidget {
  const GlassChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.multiSelect = false,
    this.avatar,
    this.chipKey,
  });

  final Widget label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final bool multiSelect;

  /// Leading widget, shown before the label on every platform.
  final Widget? avatar;

  /// Key for the rendered chip itself: the [ChoiceChip]/[FilterChip] off
  /// Liquid Glass, the capsule on it. Use it instead of `key` when a
  /// test needs to read the chip widget, since `key` sits on [GlassChip].
  final Key? chipKey;

  static const double _height = LiquidGeometry.buttonMedium;
  static const double _frostedHeight = 30;
  static const double _frostedRadius = 8;

  @override
  Widget build(BuildContext context) {
    final onSelected = this.onSelected;
    final avatar = this.avatar;
    if (!GlassStyle.of(context)) {
      final palette = context.palette;
      final foreground = selected ? palette.background : palette.textPrimary;
      final radius = BorderRadius.circular(_frostedRadius);
      final shape = RoundedRectangleBorder(borderRadius: radius);
      // Passed as the widget's own side: the chip prefers it over the
      // theme's (none) and over the shape's, so a hairline set only on the
      // shape never shows.
      final side = BorderSide(color: context.surfaceRoles.hairlineStrong);
      final labelStyle = TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w500,
        color: foreground,
      );
      final chip = multiSelect
          ? FilterChip(
              key: chipKey,
              avatar: avatar,
              label: label,
              selected: selected,
              onSelected: onSelected,
              showCheckmark: false,
              shape: shape,
              side: side,
              backgroundColor: Colors.transparent,
              selectedColor: Colors.white,
              labelStyle: labelStyle,
              iconTheme: IconThemeData(color: foreground),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )
          : ChoiceChip(
              key: chipKey,
              avatar: avatar,
              label: label,
              selected: selected,
              onSelected: onSelected,
              showCheckmark: false,
              shape: shape,
              side: side,
              backgroundColor: Colors.transparent,
              selectedColor: Colors.white,
              labelStyle: labelStyle,
              iconTheme: IconThemeData(color: foreground),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            );
      return GlassHitTarget(
        height: _frostedHeight,
        onTap: onSelected == null ? null : () => onSelected(!selected),
        child: FocusEmphasis(
          size: FocusSize.control,
          borderRadius: radius,
          child: PressScale(
            enabled: onSelected != null,
            // At least the spec's height; a large text scale grows it rather
            // than clipping the label.
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: _frostedHeight),
              child: chip,
            ),
          ),
        ),
      );
    }
    final palette = context.palette;
    final foreground = selected ? palette.background : palette.textPrimary;
    const radius = BorderRadius.all(Radius.circular(_height / 2));
    final onTap = onSelected == null ? null : () => onSelected(!selected);
    return GlassHitTarget(
      height: _height,
      onTap: onTap,
      child: Semantics(
        key: chipKey,
        button: true,
        selected: selected,
        child: GlassInteraction(
          enabled: onSelected != null,
          child: GlassSurface.control(
            borderRadius: radius,
            prominentColor: selected ? Colors.white : null,
            grouped: BackdropGroup.of(context) != null,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: radius,
                splashFactory: NoSplash.splashFactory,
                onTap: onTap,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: _height),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Center(
                      widthFactor: 1,
                      heightFactor: 1,
                      child: IconTheme.merge(
                        data: IconThemeData(color: foreground),
                        child: DefaultTextStyle.merge(
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: foreground,
                                fontWeight: FontWeight.w600,
                              ),
                          child: avatar == null
                              ? label
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    avatar,
                                    const SizedBox(width: 6),
                                    label,
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
