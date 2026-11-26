// The Liquid Glass legibility contract, computed from the tokens.
//
// Worst case is the tint after adaptation over a pure-white backdrop: the
// backdrop luma is 1, so the alpha is the role's adaptive max. Refraction
// and blur are the identity over a uniform frame, saturation clamps at
// white, brightness is modelled as each profile's lift of the grey
// (clamped at white), and the specular only adds light at the rim, away
// from glyphs. The model lifts only, which stays conservative: the shader's
// luminosity wash pulls luminance toward 0.1, so over the bright backdrops
// that set the worst case it only darkens. It can lift near-black, but only
// up to 0.1 times lumaMix, never above 0.1. All presets are dark, so white is the worst backdrop. Text
// holds WCAG SC 1.4.3 (4.5:1), icons and secondary text SC 1.4.11 (3:1).

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_colors.dart';
import 'package:player/core/theme/contrast.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_profile.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_adaptive.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/theme_preset.dart';

import 'package:player/presentation/widgets/video_controls/chrome_scrim.dart';
import 'package:player/presentation/widgets/video_controls/chrome_title_block.dart';

import '../../../test_utils/mac_accents.dart' show macAccents;
import '../../../test_utils/osd_contrast.dart'
    show compositeOver, osdIconOnlyColors, osdTextColors;

const _white = Color(0xFFFFFFFF);

Color _over(Color base, double alpha) =>
    Color.alphaBlend(base.withValues(alpha: alpha), _white);

Color _grey(double v, double lift) => Color.from(
  alpha: 1,
  red: (v + lift).clamp(0.0, 1.0),
  green: (v + lift).clamp(0.0, 1.0),
  blue: (v + lift).clamp(0.0, 1.0),
);

Color _overGrey(Color base, double alpha, double v, double lift) =>
    Color.alphaBlend(base.withValues(alpha: alpha), _grey(v, lift));

/// The OSD glyph colours a surface role draws, from the legibility contract
/// in `osd_contrast.dart`.
///
/// Pills draw white at several alphas and `textPrimary` (the touch transport
/// glyph); status, accent and secondary tones only ever appear on panels
/// (dialogs, sheets, stats), so rating them on a pill would only force the
/// pill opaque. Panels draw every contract colour except `textSecondary`,
/// which holds 3:1 per preset in 'OSD panel secondary text' (4.5:1 would
/// need an almost opaque panel).
Set<Color> _osdTextFor(String role) {
  bool white(Color c) => c.r == 1 && c.g == 1 && c.b == 1;
  final secondary = Palettes.projectionBooth.textSecondary;
  final primary = Palettes.projectionBooth.textPrimary;
  return osdTextColors
      .where(
        (c) => role == 'pill' ? (white(c) || c == primary) : c != secondary,
      )
      .toSet();
}

/// Every colour [role] draws, composited over [bg] (glyph alpha included):
/// text colours 4.5:1, icon-only colours 3:1.
///
/// `palette.primary` is in [osdTextColors] (it is the contract's set), so it
/// is rated as text on panels.
void _expectOsdColours(String role, Color bg, String reason) {
  for (final c in _osdTextFor(role)) {
    expect(
      contrastRatio(compositeOver(c, bg), bg),
      greaterThanOrEqualTo(4.5),
      reason: '$reason, text $c',
    );
  }
  if (role != 'panel') return;
  for (final c in osdIconOnlyColors) {
    expect(
      contrastRatio(compositeOver(c, bg), bg),
      greaterThanOrEqualTo(3.0),
      reason: '$reason, icon $c',
    );
  }
}

void main() {
  final roles =
      <String, (Color Function(AmbientTintColors), double, double, double)>{
        'chrome (ground)': (
          (t) => t.ground,
          DepthTokens.liquidChromeTintOpacity,
          DepthTokens.liquidChromeAdaptiveMax,
          LiquidGlassProfile.lens.brightness,
        ),
        'chrome (surface)': (
          (t) => t.surface,
          DepthTokens.liquidChromeTintOpacity,
          DepthTokens.liquidChromeAdaptiveMax,
          LiquidGlassProfile.lens.brightness,
        ),
        'sidebar': (
          (t) => t.surface,
          DepthTokens.liquidChromeTintOpacity,
          DepthTokens.liquidChromeAdaptiveMax,
          LiquidGlassProfile.panel.brightness,
        ),
        'modal': (
          (t) => t.surface,
          DepthTokens.liquidModalTintOpacity,
          DepthTokens.liquidModalAdaptiveMax,
          LiquidGlassProfile.panel.brightness,
        ),
      };

  for (final preset in ThemePreset.values) {
    final palette = preset.palette(systemAccent: Palettes.macosDefaultAccent);
    final tint = AmbientTintColors.neutralFor(palette);

    group('${preset.name} over pure white', () {
      roles.forEach((name, role) {
        final (pick, base, max, lift) = role;
        final alpha = liquidAdaptiveAlpha(
          base: base,
          max: max,
          backdropLuma: 1.0,
        );
        final bg = _over(pick(tint), alpha);
        test('$name: text clears 4.5:1', () {
          expect(
            contrastRatio(palette.textPrimary, bg),
            greaterThanOrEqualTo(4.5),
          );
        });
        test('$name: secondary clears 3:1', () {
          expect(
            contrastRatio(palette.textSecondary, bg),
            greaterThanOrEqualTo(3.0),
          );
        });
      });

      test('control: icons clear 3:1', () {
        final alpha = liquidAdaptiveAlpha(
          base: DepthTokens.liquidControlTintOpacity,
          max: DepthTokens.liquidControlAdaptiveMax,
          backdropLuma: 1.0,
        );
        final bg = _over(tint.surface, alpha);
        expect(
          contrastRatio(palette.textPrimary, bg),
          greaterThanOrEqualTo(3.0),
        );
      });

      test(
        'control: frosted fallback keeps white labels at 4.5:1 over white',
        () {
          final bg = _over(tint.surface, DepthTokens.liquidControlAdaptiveMax);
          expect(contrastRatio(Colors.white, bg), greaterThanOrEqualTo(4.5));
        },
      );

      test('scroll edge band top: title text clears 4.5:1', () {
        final bg = _over(tint.ground, DepthTokens.liquidScrollEdgeTopOpacity);
        expect(
          contrastRatio(palette.textPrimary, bg),
          greaterThanOrEqualTo(4.5),
        );
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
            final alpha = liquidAdaptiveAlpha(
              base: base,
              max: max,
              backdropLuma: v,
            );
            final bg = _overGrey(pick(tint), alpha, v, lift);
            expect(
              contrastRatio(palette.textPrimary, bg),
              greaterThanOrEqualTo(4.5),
              reason: 'text at grey $v',
            );
            expect(
              contrastRatio(palette.textSecondary, bg),
              greaterThanOrEqualTo(3.0),
              reason: 'secondary at grey $v',
            );
          }
        });
      });

      test('control: icons clear 3:1 at every grey', () {
        for (final v in greys) {
          final alpha = liquidAdaptiveAlpha(
            base: DepthTokens.liquidControlTintOpacity,
            max: DepthTokens.liquidControlAdaptiveMax,
            backdropLuma: v,
          );
          final bg = _overGrey(
            tint.surface,
            alpha,
            v,
            LiquidGlassProfile.lens.brightness,
          );
          expect(
            contrastRatio(palette.textPrimary, bg),
            greaterThanOrEqualTo(3.0),
            reason: 'icon at grey $v',
          );
        }
      });

      test(
        'control: white labels (Play, glass buttons) clear 4.5:1 at every grey',
        () {
          for (final v in greys) {
            final alpha = liquidAdaptiveAlpha(
              base: DepthTokens.liquidControlTintOpacity,
              max: DepthTokens.liquidControlAdaptiveMax,
              backdropLuma: v,
            );
            final bg = _overGrey(
              tint.surface,
              alpha,
              v,
              LiquidGlassProfile.lens.brightness,
            );
            expect(
              contrastRatio(Colors.white, bg),
              greaterThanOrEqualTo(4.5),
              reason: 'label at grey $v',
            );
          }
        },
      );
    });
  }

  test('the prominent pill label clears 4.5:1 over pure black', () {
    final bg = Color.alphaBlend(
      Colors.white.withValues(alpha: DepthTokens.liquidProminentTintOpacity),
      const Color(0xFF000000),
    );
    for (final preset in ThemePreset.values) {
      final palette = preset.palette(systemAccent: Palettes.macosDefaultAccent);
      expect(
        contrastRatio(palette.background, bg),
        greaterThanOrEqualTo(4.5),
        reason: preset.name,
      );
    }
  });

  group('OSD sampled', () {
    // The OSD tints with osdTint, not the ambient surface. The scrim gets no
    // credit: this is the conservative case. Every colour the OSD draws
    // (osdTextColors at 4.5:1, osdIconOnlyColors at 3:1) is rated, composited
    // over the glass, because pills draw translucent whites, not pure white.
    final osdRoles = <String, (double, double, double)>{
      'pill': (
        DepthTokens.liquidControlTintOpacity,
        DepthTokens.liquidControlAdaptiveMax,
        LiquidGlassProfile.lens.brightness,
      ),
      'panel': (
        DepthTokens.liquidModalTintOpacity,
        DepthTokens.liquidModalAdaptiveMax,
        LiquidGlassProfile.panel.brightness,
      ),
    };
    osdRoles.forEach((name, role) {
      final (base, max, lift) = role;
      test('$name: every OSD text colour clears 4.5:1 and icon 3:1', () {
        for (final v in greys) {
          final alpha = liquidAdaptiveAlpha(
            base: base,
            max: max,
            backdropLuma: v,
          );
          final bg = _overGrey(DepthTokens.osdTint, alpha, v, lift);
          _expectOsdColours(name, bg, '$name sampled grey $v');
        }
      });
    });
  });

  group('OSD panel secondary text', () {
    // Panels (dialogs, pickers, stats) draw textSecondary, so every preset's
    // must hold 3:1 and white 4.5:1 across the sweep.
    for (final preset in ThemePreset.values) {
      final palette = preset.palette(systemAccent: Palettes.macosDefaultAccent);
      test('${preset.name}: sampled', () {
        for (final v in greys) {
          final alpha = liquidAdaptiveAlpha(
            base: DepthTokens.liquidModalTintOpacity,
            max: DepthTokens.liquidModalAdaptiveMax,
            backdropLuma: v,
          );
          final bg = _overGrey(
            DepthTokens.osdTint,
            alpha,
            v,
            LiquidGlassProfile.panel.brightness,
          );
          expect(
            contrastRatio(palette.textSecondary, bg),
            greaterThanOrEqualTo(3.0),
            reason: 'secondary at grey $v',
          );
        }
      });

      test('${preset.name}: dry', () {
        for (final v in greys) {
          final bg = Color.alphaBlend(
            Colors.white.withValues(alpha: DepthTokens.osdDryCatchLightAlpha),
            _overGrey(
              DepthTokens.osdTint,
              DepthTokens.osdDryPanelTintOpacity,
              v,
              0,
            ),
          );
          expect(
            contrastRatio(palette.textSecondary, bg),
            greaterThanOrEqualTo(3.0),
            reason: 'secondary at grey $v',
          );
          expect(
            contrastRatio(Colors.white, bg),
            greaterThanOrEqualTo(4.5),
            reason: 'label at grey $v',
          );
        }
      });
    }
  });

  group('OSD dry', () {
    // Dry glass has no backdrop to adapt to, so one fixed tint must hold over
    // every grey the video can show.
    final greys = [for (var i = 0; i <= 20; i++) i / 20];
    final roles = <String, double>{
      'pill': DepthTokens.osdDryTintOpacity,
      'panel': DepthTokens.osdDryPanelTintOpacity,
    };
    roles.forEach((name, tint) {
      test('$name: every OSD text colour clears 4.5:1 and icon 3:1', () {
        for (final v in greys) {
          // Tint, then the catch light at its peak, then the glyph.
          final bg = Color.alphaBlend(
            Colors.white.withValues(alpha: DepthTokens.osdDryCatchLightAlpha),
            _overGrey(DepthTokens.osdTint, tint, v, 0),
          );
          _expectOsdColours(name, bg, '$name dry grey $v');
        }
      });
    });
  });

  group('OSD dry, pressed', () {
    // The press glow is white at its peak alpha over the tint and the catch
    // light, so it lifts the fill the glyph sits on. Dry-specific token: the sampled
    // shader keeps DepthTokens.liquidPressGlow.
    final greys = [for (var i = 0; i <= 20; i++) i / 20];
    test('pill: every OSD text colour clears 4.5:1', () {
      // Icon-only colours (the error red) never sit on a pill: as in the
      // unpressed sweep, they are rated on panels, which are not pressable.
      for (final v in greys) {
        final bg = Color.alphaBlend(
          Colors.white.withValues(alpha: DepthTokens.osdDryPressGlow),
          Color.alphaBlend(
            Colors.white.withValues(alpha: DepthTokens.osdDryCatchLightAlpha),
            _overGrey(DepthTokens.osdTint, DepthTokens.osdDryTintOpacity, v, 0),
          ),
        );
        for (final c in _osdTextFor('pill')) {
          expect(
            contrastRatio(compositeOver(c, bg), bg),
            greaterThanOrEqualTo(4.5),
            reason: 'pressed pill grey $v, text $c',
          );
        }
      }
    });
  });

  group('OSD dry panel, macOS accents', () {
    // The accent is lifted against the OSD fill, which is not the dry panel
    // (tint plus catch light), so rate every system accent on the panel too.
    for (final a in macAccents.entries) {
      test('${a.key}: primary clears 4.5:1 on the dry panel', () {
        final primary = ThemePreset.macos
            .palette(systemAccent: a.value)
            .primary;
        for (final v in [for (var i = 0; i <= 20; i++) i / 20]) {
          final bg = Color.alphaBlend(
            Colors.white.withValues(alpha: DepthTokens.osdDryCatchLightAlpha),
            _overGrey(
              DepthTokens.osdTint,
              DepthTokens.osdDryPanelTintOpacity,
              v,
              0,
            ),
          );
          expect(
            contrastRatio(primary, bg),
            greaterThanOrEqualTo(4.5),
            reason: '${a.key} at grey $v',
          );
        }
      });
    }
  });

  group('OSD title on the scrim', () {
    // The title is bare text on the scrim in every mode, so sampled and dry
    // share one alpha: the scrim's, at the title block's top edge. There is
    // no glass profile to credit. Rated over the grey sweep 0 to 1.
    final sweep = [for (var i = 0; i <= 20; i++) i / 20];
    for (final mode in const ['sampled', 'dry']) {
      for (final tier in ChromeTitleTier.values) {
        test('$mode, ${tier.name}: title 3:1 and kicker 4.5:1', () {
          final titleHeight =
              ChromeTitleBlock.heightFor(tier) + ChromeTitleBlock.gapFor(tier);
          final alpha = ChromeScrim.alphaAt(
            100 + titleHeight,
            plateau: 100,
            titleHeight: titleHeight,
            height: tier == ChromeTitleTier.compact ? 350 : 1080,
          );
          for (final v in sweep) {
            final bg = _overGrey(DepthTokens.osdTint, alpha, v, 0);
            expect(
              contrastRatio(
                compositeOver(_white.withValues(alpha: 0.95), bg),
                bg,
              ),
              greaterThanOrEqualTo(3.0),
              reason: '$mode ${tier.name} title at grey $v',
            );
            expect(
              contrastRatio(
                compositeOver(
                  _white.withValues(alpha: ChromeTitleBlock.kickerOpacity),
                  bg,
                ),
                bg,
              ),
              greaterThanOrEqualTo(4.5),
              reason: '$mode ${tier.name} kicker at grey $v',
            );
          }
        });
      }
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
