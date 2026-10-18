// The Liquid Glass legibility contract, computed from the tokens.
//
// Worst case is the tint after adaptation over a pure-white backdrop: the
// backdrop luma is 1, so the alpha is the role's adaptive max. Refraction and
// blur are the identity over a uniform frame, saturation and brightness
// clamp at white, and the specular only adds light at the rim, away from
// glyphs. All presets are dark, so white is the worst backdrop. Text holds
// WCAG SC 1.4.3 (4.5:1), icons and secondary text SC 1.4.11 (3:1).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_colors.dart';
import 'package:player/core/theme/contrast.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_adaptive.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/theme_preset.dart';

const _white = Color(0xFFFFFFFF);

Color _over(Color base, double alpha) =>
    Color.alphaBlend(base.withValues(alpha: alpha), _white);

void main() {
  final roles = <String, (Color Function(AmbientTintColors), double, double)>{
    'chrome (ground)': (
      (t) => t.ground,
      DepthTokens.liquidChromeTintOpacity,
      DepthTokens.liquidChromeAdaptiveMax
    ),
    'chrome (surface)': (
      (t) => t.surface,
      DepthTokens.liquidChromeTintOpacity,
      DepthTokens.liquidChromeAdaptiveMax
    ),
    'modal': (
      (t) => t.surface,
      DepthTokens.liquidModalTintOpacity,
      DepthTokens.liquidModalAdaptiveMax
    ),
  };

  for (final preset in ThemePreset.values) {
    final palette = preset.palette(systemAccent: Palettes.macosDefaultAccent);
    final tint = AmbientTintColors.neutralFor(palette);

    group('${preset.name} over pure white', () {
      roles.forEach((name, role) {
        final (pick, base, max) = role;
        final alpha =
            liquidAdaptiveAlpha(base: base, max: max, backdropLuma: 1.0);
        final bg = _over(pick(tint), alpha);
        test('$name: text clears 4.5:1', () {
          expect(contrastRatio(palette.textPrimary, bg),
              greaterThanOrEqualTo(4.5));
        });
        test('$name: secondary clears 3:1', () {
          expect(contrastRatio(palette.textSecondary, bg),
              greaterThanOrEqualTo(3.0));
        });
      });

      test('control: icons clear 3:1', () {
        final alpha = liquidAdaptiveAlpha(
            base: DepthTokens.liquidControlTintOpacity,
            max: DepthTokens.liquidControlAdaptiveMax,
            backdropLuma: 1.0);
        final bg = _over(tint.surface, alpha);
        expect(
            contrastRatio(palette.textPrimary, bg), greaterThanOrEqualTo(3.0));
      });

      test('scroll edge band top: title text clears 4.5:1', () {
        final bg = _over(tint.ground, DepthTokens.liquidScrollEdgeTopOpacity);
        expect(
            contrastRatio(palette.textPrimary, bg), greaterThanOrEqualTo(4.5));
      });

      test('accent Play label clears 4.5:1 over white and black', () {
        final accent = accentGlassTint(palette.primary);
        final overWhite = _over(
            accent,
            liquidAdaptiveAlpha(
                base: DepthTokens.liquidAccentTintOpacity,
                max: DepthTokens.liquidAccentAdaptiveMax,
                backdropLuma: 1.0));
        final overBlack = Color.alphaBlend(
            accent.withValues(alpha: DepthTokens.liquidAccentTintOpacity),
            const Color(0xFF000000));
        expect(
            contrastRatio(Colors.white, overWhite), greaterThanOrEqualTo(4.5));
        expect(
            contrastRatio(Colors.white, overBlack), greaterThanOrEqualTo(4.5));
      });
    });
  }

  test('the prominent pill label clears 4.5:1 over pure black', () {
    final bg = Color.alphaBlend(
      Colors.white.withValues(alpha: DepthTokens.liquidProminentTintOpacity),
      const Color(0xFF000000),
    );
    for (final preset in ThemePreset.values) {
      final palette = preset.palette(systemAccent: Palettes.macosDefaultAccent);
      expect(contrastRatio(palette.background, bg), greaterThanOrEqualTo(4.5),
          reason: preset.name);
    }
  });

  test('every adaptive max clears the legibility floor', () {
    for (final alpha in [
      DepthTokens.liquidChromeAdaptiveMax,
      DepthTokens.liquidModalAdaptiveMax,
      DepthTokens.liquidControlAdaptiveMax,
      DepthTokens.liquidScrollEdgeTopOpacity,
    ]) {
      expect(alpha, greaterThanOrEqualTo(DepthTokens.glassLegibilityFloor));
    }
  });
}
