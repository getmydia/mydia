import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../contrast.dart';
import '../depth_tokens.dart';

/// The tint alpha the Liquid Glass shader uses at a pixel whose brightest
/// nearby backdrop luma is [backdropLuma] (0..1): [base] over dark content,
/// rising by smoothstep to [max] over bright content. Mirrors `liquid_glass.frag` exactly, so the
/// legibility test checks the shader's own maths.
double liquidAdaptiveAlpha({
  required double base,
  required double max,
  required double backdropLuma,
}) {
  const lo = DepthTokens.liquidAdaptiveLumaLow;
  const hi = DepthTokens.liquidAdaptiveLumaHigh;
  final t = ((backdropLuma - lo) / (hi - lo)).clamp(0.0, 1.0);
  final s = t * t * (3 - 2 * t);
  final ceiling = math.max(max, base);
  return base + (ceiling - base) * s;
}

const Color _white = Color(0xFFFFFFFF);

/// The accent as a glass tint that keeps a white label at 4.5:1 even over
/// pure white, where the tint sits at [DepthTokens.liquidAccentAdaptiveMax].
/// Darkens the accent's lightness until it does; a dark enough accent comes
/// back unchanged.
Color accentGlassTint(Color accent) {
  bool clears(Color c) =>
      contrastRatio(
        _white,
        Color.alphaBlend(
            c.withValues(alpha: DepthTokens.liquidAccentAdaptiveMax), _white),
      ) >=
      4.5;
  final opaque = accent.withValues(alpha: 1);
  if (clears(opaque)) return opaque;
  var hsl = HSLColor.fromColor(opaque);
  while (hsl.lightness > 0) {
    hsl = hsl.withLightness(math.max(0, hsl.lightness - 0.02));
    final c = hsl.toColor();
    if (clears(c)) return c;
  }
  return hsl.toColor();
}
