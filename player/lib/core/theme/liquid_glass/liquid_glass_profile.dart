import 'package:flutter/foundation.dart';

import '../depth_tokens.dart';

/// The shader values that differ between Liquid Glass materials.
///
/// [lens] is the floating control layer: refraction and colour fringing at
/// the rim, a specular rim lit from above and below, and an inner glow. On a
/// 400px dialog the same rim reads as polished chrome, so large surfaces take
/// [panel]: a heavier blur, no lens, one soft highlight on the top edge and
/// an even hairline. Tint and adaptive tint stay per surface.
@immutable
class LiquidGlassProfile {
  const LiquidGlassProfile({
    required this.blurSigma,
    required this.edgeBand,
    required this.refraction,
    required this.dispersion,
    required this.saturation,
    required this.brightness,
    required this.specular,
    required this.rimWidth,
    required this.rimHairline,
    required this.bottomLight,
    required this.innerGlow,
    required this.interactive,
  });

  /// Buttons, chips, badges, the dock pill and the cast pill.
  static const LiquidGlassProfile lens = LiquidGlassProfile(
    blurSigma: DepthTokens.liquidBlurSigma,
    edgeBand: DepthTokens.liquidEdgeBand,
    refraction: DepthTokens.liquidRefraction,
    dispersion: DepthTokens.liquidDispersion,
    saturation: DepthTokens.liquidSaturation,
    brightness: DepthTokens.liquidBrightness,
    specular: DepthTokens.liquidSpecular,
    rimWidth: DepthTokens.liquidRimWidth,
    rimHairline: DepthTokens.liquidRimHairline,
    bottomLight: DepthTokens.liquidBottomLight,
    innerGlow: DepthTokens.liquidInnerGlow,
    interactive: true,
  );

  /// Dialogs, sheets, popovers, the login cards and the floating sidebar.
  static const LiquidGlassProfile panel = LiquidGlassProfile(
    blurSigma: DepthTokens.liquidPanelBlurSigma,
    edgeBand: DepthTokens.liquidEdgeBand,
    refraction: 0,
    dispersion: 0,
    saturation: DepthTokens.liquidPanelSaturation,
    brightness: DepthTokens.liquidPanelBrightness,
    specular: DepthTokens.liquidPanelSpecular,
    rimWidth: DepthTokens.liquidPanelRimWidth,
    rimHairline: DepthTokens.liquidPanelRimHairline,
    bottomLight: 0,
    innerGlow: 0,
    interactive: false,
  );

  /// Gaussian blur under the shader.
  final double blurSigma;

  /// Width of the band along the edge where the backdrop is bent.
  final double edgeBand;

  /// Backdrop displacement at the very rim.
  final double refraction;

  /// Extra displacement of red over blue, as a fraction of [refraction].
  final double dispersion;

  final double saturation;
  final double brightness;

  /// Specular rim intensity at rest.
  final double specular;
  final double rimWidth;

  /// Rim light on every edge, as a fraction of [specular].
  final double rimHairline;

  /// The bottom edge's highlight relative to the top edge's.
  final double bottomLight;

  /// Light across the edge band on the top and bottom edges.
  final double innerGlow;

  /// Whether hover and press boost the rim and add a press glow.
  final bool interactive;
}
