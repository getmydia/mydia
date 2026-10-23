import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// The shader values that differ between Liquid Glass materials.
///
/// [lens] is the floating control layer: a frosted blur, a bent rim, and a
/// specular rim lit from above and below. It keeps the material it had before
/// the iOS 27 kit mapping, because the kit's Small UI values rendered nearly
/// clear with a white outline here. Large surfaces take [panel], the kit's
/// Large UI: a heavier blur and a luminosity wash with a discreet edge.
/// [clear] is the kit's clear glass for slider and segmented thumbs. Tint and
/// adaptive tint stay per surface.
@immutable
class LiquidGlassProfile {
  const LiquidGlassProfile({
    required this.blurSigma,
    required this.depth,
    required this.distortion,
    required this.dispersion,
    required this.saturation,
    required this.brightness,
    required this.lumaTarget,
    required this.lumaMix,
    required this.specular,
    required this.rimWidth,
    required this.rimHairline,
    required this.sideLight,
    required this.bottomLight,
    required this.innerGlow,
    required this.volumeSide,
    required this.volumeEnds,
    required this.interactive,
    required this.shadow,
  });

  /// Small UI in the kit: buttons, chips, badges, the dock pill, the cast
  /// pill. The kit's Small UI (blur 6, distortion 0.4, depth 0.8, side and
  /// volume light) rendered nearly clear with a white outline here, so the
  /// lens keeps the frosted material it had before the kit mapping: a heavy
  /// blur, a rim lit at the top and bottom, a faint hairline elsewhere, and
  /// the kit's shadow. Tune it by eye with `./dev player glass-diff`.
  static const LiquidGlassProfile lens = LiquidGlassProfile(
    blurSigma: 20,
    depth: 0.4,
    distortion: 1.25,
    dispersion: 0.05,
    saturation: 1.3,
    brightness: 0.07,
    lumaTarget: 0,
    lumaMix: 0,
    specular: 0.85,
    rimWidth: 1.5,
    rimHairline: 0.12,
    sideLight: 0,
    bottomLight: 0.6,
    innerGlow: 0.12,
    volumeSide: 0,
    volumeEnds: 0,
    interactive: true,
    shadow: [
      BoxShadow(color: Color(0x0A000000), blurRadius: 15, offset: Offset(0, 8)),
    ],
  );

  /// Large UI in the kit: dialogs, sheets, popovers, menus, the login cards
  /// and the floating sidebar. Kit: blur 30, saturation 1.2, distortion 0.3,
  /// depth 0.9, a grey 25 luminosity wash, shadow 0 18 48 at 45%. [lumaMix]
  /// uses the Medium UI share: the Large share plus our role tint reads as an
  /// opaque slab.
  static const LiquidGlassProfile panel = LiquidGlassProfile(
    blurSigma: 15,
    depth: 0.9,
    distortion: 0.3,
    dispersion: 0,
    saturation: 1.2,
    brightness: 0,
    lumaTarget: 0.1,
    lumaMix: 0.3,
    specular: 0.45,
    rimWidth: 1.0,
    rimHairline: 0.4,
    sideLight: 0.4,
    bottomLight: 0.3,
    innerGlow: 0,
    volumeSide: 0,
    volumeEnds: 0.08,
    interactive: false,
    shadow: [
      BoxShadow(
          color: Color(0x73000000), blurRadius: 48, offset: Offset(0, 18)),
    ],
  );

  /// Clear glass in the kit: slider and segmented thumbs. No blur,
  /// distortion 0.08, depth 0.4. The shadow is not from the kit; it keeps the
  /// knob visible over a flat track.
  static const LiquidGlassProfile clear = LiquidGlassProfile(
    blurSigma: 0,
    depth: 0.4,
    distortion: 0.08,
    dispersion: 0,
    saturation: 1.0,
    brightness: 0.02,
    lumaTarget: 0,
    lumaMix: 0,
    specular: 0.85,
    rimWidth: 1.0,
    rimHairline: 0.5,
    sideLight: 0.6,
    bottomLight: 0.6,
    innerGlow: 0,
    volumeSide: 0,
    volumeEnds: 0,
    interactive: true,
    shadow: [
      BoxShadow(color: Color(0x26000000), blurRadius: 8, offset: Offset(0, 2)),
    ],
  );

  /// Gaussian blur under the shader.
  final double blurSigma;

  /// Edge band as a fraction of the corner radius (the kit's depth).
  final double depth;

  /// Rim displacement as a fraction of the edge band (the kit's distortion).
  final double distortion;

  /// Extra displacement of red over blue, as a fraction of the displacement.
  final double dispersion;

  final double saturation;
  final double brightness;

  /// Luminance the backdrop is pulled toward, and how far (the kit's
  /// luminosity wash; hue survives).
  final double lumaTarget;
  final double lumaMix;

  /// Specular rim intensity at rest.
  final double specular;
  final double rimWidth;

  /// Rim light on every edge, as a fraction of [specular].
  final double rimHairline;

  /// Rim light on the left and right edges, relative to the top.
  final double sideLight;

  /// The bottom edge's highlight relative to the top edge's.
  final double bottomLight;

  /// Light across the edge band on the top and bottom edges.
  final double innerGlow;

  /// Light lifted toward the left and right of the interior.
  final double volumeSide;

  /// Light taken from the interior near the top and bottom.
  final double volumeEnds;

  /// Whether hover and press boost the rim and add a press glow.
  final bool interactive;

  /// Drop shadow under the surface.
  final List<BoxShadow> shadow;
}
