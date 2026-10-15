import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import '../colors.dart';

/// The two colours the ambient tint drives: the ground behind content and the
/// surface glass chrome is filled with.
///
/// The neutral value is today's palette exactly, so a screen with no artwork
/// renders as it did before the tint existed.
@immutable
class AmbientTintColors {
  const AmbientTintColors({required this.ground, required this.surface});

  static const AmbientTintColors neutral = AmbientTintColors(
    ground: AppColors.background,
    surface: AppColors.surface,
  );

  /// Tone bounds for a tinted ground. The ceiling is what keeps
  /// `AppColors.textSecondary` at 4.5:1 (ambient_tint_colors_test.dart).
  static const double minTone = 14;
  static const double maxTone = 20;

  /// Chroma ceiling, so saturated art reads as a tint rather than a colour.
  static const double maxChroma = 48;

  /// Below this the art is effectively grey and the neutral tint is used.
  static const double minSeedChroma = 8;

  final Color ground;
  final Color surface;

  /// Clamps [seed] into a dark, legible ground. Hue is kept as is.
  factory AmbientTintColors.fromSeed(Color seed) {
    final hct = Hct.fromInt(seed.toARGB32());
    final tone = hct.tone.clamp(minTone, maxTone).toDouble();
    final chroma = math.min(hct.chroma, maxChroma);
    final ground = Color(Hct.from(hct.hue, chroma, tone).toInt());
    return AmbientTintColors(ground: ground, surface: ground);
  }

  static AmbientTintColors lerp(
    AmbientTintColors a,
    AmbientTintColors b,
    double t,
  ) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    return AmbientTintColors(
      ground: Color.lerp(a.ground, b.ground, t) ?? b.ground,
      surface: Color.lerp(a.surface, b.surface, t) ?? b.surface,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AmbientTintColors &&
      other.ground == ground &&
      other.surface == surface;

  @override
  int get hashCode => Object.hash(ground, surface);
}
