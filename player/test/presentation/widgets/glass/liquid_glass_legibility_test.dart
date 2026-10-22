// The Liquid Glass legibility contract, computed from the tokens.
//
// Worst case is the tint after adaptation over a pure-white backdrop: the
// backdrop luma is 1, so the alpha is the role's adaptive max. Refraction and
// blur are the identity over a uniform frame, saturation clamps at white,
// brightness is modelled as each profile's lift of the grey (clamped at white), and the specular only adds light at the rim, away from
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

Color _grey(double v, double lift) => Color.from(
    alpha: 1,
    red: (v + lift).clamp(0.0, 1.0),
    green: (v + lift).clamp(0.0, 1.0),
    blue: (v + lift).clamp(0.0, 1.0));

Color _overGrey(Color base, double alpha, double v, double lift) =>
    Color.alphaBlend(base.withValues(alpha: alpha), _grey(v, lift));

void main() {
  final roles =
      <String, (Color Function(AmbientTintColors), double, double, double)>{
    'chrome (ground)': (
      (t) => t.ground,
      DepthTokens.liquidChromeTintOpacity,
      DepthTokens.liquidChromeAdaptiveMax,
      DepthTokens.liquidBrightness,
    ),
    'chrome (surface)': (
      (t) => t.surface,
      DepthTokens.liquidChromeTintOpacity,
      DepthTokens.liquidChromeAdaptiveMax,
      DepthTokens.liquidBrightness,
    ),
    'sidebar': (
      (t) => t.surface,
      DepthTokens.liquidChromeTintOpacity,
      DepthTokens.liquidChromeAdaptiveMax,
      DepthTokens.liquidPanelBrightness,
    ),
    'modal': (
      (t) => t.surface,
      DepthTokens.liquidModalTintOpacity,
      DepthTokens.liquidModalAdaptiveMax,
      DepthTokens.liquidPanelBrightness,
    ),
  };

  for (final preset in ThemePreset.values) {
    final palette = preset.palette(systemAccent: Palettes.macosDefaultAccent);
    final tint = AmbientTintColors.neutralFor(palette);

    group('${preset.name} over pure white', () {
      roles.forEach((name, role) {
        final (pick, base, max, lift) = role;
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

      test('control: frosted fallback keeps white labels at 4.5:1 over white',
          () {
        final bg = _over(tint.surface, DepthTokens.liquidControlAdaptiveMax);
        expect(contrastRatio(Colors.white, bg), greaterThanOrEqualTo(4.5));
      });

      test('scroll edge band top: title text clears 4.5:1', () {
        final bg = _over(tint.ground, DepthTokens.liquidScrollEdgeTopOpacity);
        expect(
            contrastRatio(palette.textPrimary, bg), greaterThanOrEqualTo(4.5));
      });
    });
  }

  // The tint is lowest at mid luma, so a mid-grey backdrop can be worse than
  // white. The shader's luma of a grey is its value (the Rec. 709 weights sum
  // to 1), and it is the brightest luma near the pixel, so a grey sweep covers
  // every uniform backdrop and the worst case under a glyph.
  final greys = [for (var i = 0; i <= 20; i++) i * 0.05];

  for (final preset in ThemePreset.values) {
    final palette = preset.palette(systemAccent: Palettes.macosDefaultAccent);
    final tint = AmbientTintColors.neutralFor(palette);

    group('${preset.name} over grey backdrops', () {
      roles.forEach((name, role) {
        final (pick, base, max, lift) = role;
        test('$name: text 4.5:1 and secondary 3:1 at every grey', () {
          for (final v in greys) {
            final alpha =
                liquidAdaptiveAlpha(base: base, max: max, backdropLuma: v);
            final bg = _overGrey(pick(tint), alpha, v, lift);
            expect(contrastRatio(palette.textPrimary, bg),
                greaterThanOrEqualTo(4.5),
                reason: 'text at grey $v');
            expect(contrastRatio(palette.textSecondary, bg),
                greaterThanOrEqualTo(3.0),
                reason: 'secondary at grey $v');
          }
        });
      });

      test('control: icons clear 3:1 at every grey', () {
        for (final v in greys) {
          final alpha = liquidAdaptiveAlpha(
              base: DepthTokens.liquidControlTintOpacity,
              max: DepthTokens.liquidControlAdaptiveMax,
              backdropLuma: v);
          final bg =
              _overGrey(tint.surface, alpha, v, DepthTokens.liquidBrightness);
          expect(
              contrastRatio(palette.textPrimary, bg), greaterThanOrEqualTo(3.0),
              reason: 'icon at grey $v');
        }
      });

      test(
          'control: white labels (Play, glass buttons) clear 4.5:1 at every grey',
          () {
        for (final v in greys) {
          final alpha = liquidAdaptiveAlpha(
              base: DepthTokens.liquidControlTintOpacity,
              max: DepthTokens.liquidControlAdaptiveMax,
              backdropLuma: v);
          final bg =
              _overGrey(tint.surface, alpha, v, DepthTokens.liquidBrightness);
          expect(contrastRatio(Colors.white, bg), greaterThanOrEqualTo(4.5),
              reason: 'label at grey $v');
        }
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
