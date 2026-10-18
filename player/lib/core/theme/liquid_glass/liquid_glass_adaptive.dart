import 'dart:math' as math;

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
