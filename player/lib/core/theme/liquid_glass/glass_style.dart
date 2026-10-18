import 'package:flutter/material.dart';

/// Whether this tree draws the Liquid Glass design language, carried on the
/// app theme so the capsule buttons in `AppTheme.build` and every glass
/// control agree. Set from `GlassMaterialSetting`.
///
/// Says nothing about the shader: `LiquidGlassSupport.available` answers
/// whether the material itself can render.
@immutable
class GlassStyle extends ThemeExtension<GlassStyle> {
  const GlassStyle({required this.liquid});

  final bool liquid;

  /// False when the theme carries no [GlassStyle] (a bare test theme).
  static bool of(BuildContext context) =>
      Theme.of(context).extension<GlassStyle>()?.liquid ?? false;

  @override
  GlassStyle copyWith({bool? liquid}) =>
      GlassStyle(liquid: liquid ?? this.liquid);

  @override
  GlassStyle lerp(covariant GlassStyle? other, double t) =>
      other == null || t < 0.5 ? this : other;
}
