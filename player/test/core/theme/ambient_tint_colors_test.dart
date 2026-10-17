// Every ground the tint can produce must keep the palette's text legible.
// This is the guard that set the tone clamp to 14..20: at tone 26,
// textSecondary measures about 3.7:1.

import 'dart:math' as math;

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_colors.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/theme_preset.dart';

double _luminance(Color color) {
  double channel(double s) =>
      s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  test('neutralFor is the palette ground and surface', () {
    for (final preset in ThemePreset.values) {
      final p = preset.palette();
      final n = AmbientTintColors.neutralFor(p);
      expect(n.ground, p.background);
      expect(n.surface, p.surface);
    }
  });

  test('resolveAmbientTint', () {
    final tint = AmbientTintColors.fromSeed(const Color(0xFF3060C0));
    expect(resolveAmbientTint(null, Palettes.slate),
        AmbientTintColors.neutralFor(Palettes.slate));
    expect(resolveAmbientTint(tint, Palettes.slate), tint);
    expect(resolveAmbientTint(tint, Palettes.oledBlack),
        AmbientTintColors.neutralFor(Palettes.oledBlack));
    expect(
        resolveAmbientTint(tint, Palettes.macos(Palettes.macosDefaultAccent)),
        AmbientTintColors.neutralFor(
            Palettes.macos(Palettes.macosDefaultAccent)));
  });

  test('fromSeed clamps tone into 14..20 and chroma to 24', () {
    final bright = AmbientTintColors.fromSeed(
      Color(Hct.from(120, 90, 85).toInt()),
    );
    final hct = Hct.fromInt(bright.ground.toARGB32());
    expect(hct.tone, inInclusiveRange(13.5, 20.5));
    expect(hct.chroma, lessThanOrEqualTo(24.5));
  });

  for (final preset in ThemePreset.values) {
    final p = preset.palette();
    if (!p.ambientTint) continue;
    group('${preset.name}: every clamped ground keeps text legible', () {
      final texts = <String, Color>{
        'textPrimary': p.textPrimary,
        'textSecondary': p.textSecondary,
        'primary': p.primary,
        'white': const Color(0xFFFFFFFF),
      };
      for (var hue = 0; hue < 360; hue += 15) {
        for (final chroma in [10.0, 30.0, 60.0, 120.0]) {
          for (final tone in [5.0, 30.0, 60.0, 95.0]) {
            final ground = AmbientTintColors.fromSeed(
              Color(Hct.from(hue.toDouble(), chroma, tone).toInt()),
            ).ground;
            texts.forEach((name, text) {
              test('$name on hue $hue chroma $chroma tone $tone', () {
                expect(_contrast(text, ground), greaterThanOrEqualTo(4.5));
              });
            });
          }
        }
      }
    });
  }

  test('lerp hits both ends', () {
    final a = AmbientTintColors.neutralFor(Palettes.projectionBooth);
    final b = AmbientTintColors.fromSeed(const Color(0xFF3E2A3A));
    expect(AmbientTintColors.lerp(a, b, 0), a);
    expect(AmbientTintColors.lerp(a, b, 1), b);
  });
}
