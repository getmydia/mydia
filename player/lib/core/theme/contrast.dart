import 'dart:math' as math;
import 'dart:ui' show Color;

/// WCAG 2.1 relative luminance. `Color.r/g/b` are gamma-encoded sRGB in
/// 0..1, so each channel is linearised before weighting.
double relativeLuminance(Color color) {
  double channel(double s) =>
      s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// WCAG 2.1 contrast ratio, order-independent.
double contrastRatio(Color a, Color b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

const Color _black = Color(0xFF000000);
const Color _white = Color(0xFFFFFFFF);

/// Label colour for a fill nobody hand-tuned (the macOS system accent).
/// One of black or white always clears 4.5:1 against any opaque colour.
Color onColorFor(Color fill) =>
    contrastRatio(_black, fill) >= contrastRatio(_white, fill)
        ? _black
        : _white;
