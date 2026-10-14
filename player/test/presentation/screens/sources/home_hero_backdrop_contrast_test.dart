// The Home hero's backdrop paints artwork behind its title, chips and
// overview. This composites the real gradient stops over worst-case white
// artwork, for the neutral ground and for the brightest ground the ambient
// tint can produce, and asserts the text clears WCAG AA (4.5:1).
//
// Only the left-to-right gradient is credited. The top and bottom gradients
// are the same ground colour, so they can only raise the opacity over the
// text, never lower it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:player/core/layout/breakpoints.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_colors.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/presentation/screens/sources/source_home_hero.dart';
import 'package:player/presentation/screens/sources/source_home_hero_backdrop.dart';

import '../../../test_utils/osd_contrast.dart';

const _white = Color(0xFFFFFFFF);
const _aa = 4.5;

/// The grounds the hero can sit on: the neutral palette and the brightest
/// tinted ground (tone 20, chroma 24) across the hue wheel.
List<Color> _grounds() => [
      AmbientTintColors.neutral.ground,
      for (var hue = 0; hue < 360; hue += 30)
        Color(
          Hct.from(
            hue.toDouble(),
            AmbientTintColors.maxChroma,
            AmbientTintColors.maxTone,
          ).toInt(),
        ),
    ];

/// The gradient's alpha at [t] (0..1 across its width).
double _alphaAt(LinearGradient g, double t) {
  final stops = g.stops!;
  if (t <= stops.first) return g.colors.first.a;
  for (var i = 1; i < stops.length; i++) {
    if (t <= stops[i]) {
      final span = stops[i] - stops[i - 1];
      final f = span == 0 ? 1.0 : (t - stops[i - 1]) / span;
      return g.colors[i - 1].a + (g.colors[i].a - g.colors[i - 1].a) * f;
    }
  }
  return g.colors.last.a;
}

Color _overWhiteArt(Color ground, double alpha) =>
    compositeOver(ground.withValues(alpha: alpha), _white);

void main() {
  const poster = SourceHomeHero.posterSize;
  const gap = 36.0;
  const maxText = 560.0;

  test('text clears 4.5:1 at the info column\'s right edge over white art', () {
    var worstTitle = double.infinity;
    var worstOverview = double.infinity;
    var worstChip = double.infinity;
    for (final ground in _grounds()) {
      for (final width in const [900.0, 1024.0, 1280.0, 1920.0, 2560.0]) {
        for (final pinned in const [false, true]) {
          final inset = Breakpoints.railContentInset(pinned: pinned);
          final padding = width >= Breakpoints.desktop ? 32.0 : 24.0;
          final gradient = HomeHeroBackdropTokens.leftGradient(
            ground: ground,
            width: width,
            inset: inset,
            padding: padding,
            posterSize: poster,
            gap: gap,
            maxTextWidth: maxText,
          );
          final textRight = HomeHeroBackdropTokens.textRightEdge(
            width: width,
            inset: inset,
            padding: padding,
            posterWidth: poster.width,
            gap: gap,
            maxTextWidth: maxText,
          );
          // Opacity falls left to right, so the right edge is the worst
          // point under any glyph.
          final alpha = _alphaAt(gradient, textRight / width);
          final bg = _overWhiteArt(ground, alpha);

          final title = contrastRatio(AppColors.textPrimary, bg);
          final pureWhite = contrastRatio(_white, bg);
          final overviewColor = compositeOver(
            AppColors.textPrimary.withValues(alpha: 0.78),
            bg,
          );
          final overview = contrastRatio(overviewColor, bg);
          final chipBg = compositeOver(_white.withValues(alpha: 0.12), bg);
          final chip = contrastRatio(AppColors.textPrimary, chipBg);

          final where = 'ground $ground, width $width, pinned $pinned';
          expect(title, greaterThanOrEqualTo(_aa), reason: 'title, $where');
          expect(pureWhite, greaterThanOrEqualTo(_aa),
              reason: 'white text, $where');
          expect(overview, greaterThanOrEqualTo(_aa),
              reason: 'overview, $where');
          expect(chip, greaterThanOrEqualTo(_aa), reason: 'chips, $where');
          worstTitle = worstTitle < title ? worstTitle : title;
          worstOverview = worstOverview < overview ? worstOverview : overview;
          worstChip = worstChip < chip ? worstChip : chip;
        }
      }
    }
    debugPrint('worst over white art: title ${worstTitle.toStringAsFixed(2)}, '
        'overview ${worstOverview.toStringAsFixed(2)}, '
        'chips ${worstChip.toStringAsFixed(2)}');
  });

  test('the ground is the weakest exactly at the text, never below textAlpha',
      () {
    final ground = AmbientTintColors.neutral.ground;
    final g = HomeHeroBackdropTokens.leftGradient(
      ground: ground,
      width: 1280,
      inset: 96,
      padding: 32,
      posterSize: poster,
      gap: gap,
      maxTextWidth: maxText,
    );
    final right = HomeHeroBackdropTokens.textRightEdge(
      width: 1280,
      inset: 96,
      padding: 32,
      posterWidth: poster.width,
      gap: gap,
      maxTextWidth: maxText,
    );
    expect(_alphaAt(g, right / 1280),
        closeTo(HomeHeroBackdropTokens.textAlpha, 1e-9));
    // The art shows beyond the text column.
    expect(_alphaAt(g, 1.0), lessThan(0.05));
  });

  test('both layouts end on the opaque ground, so what follows sits on it', () {
    expect(HomeHeroBackdropTokens.bottomStops.last, 1.0);
    expect(HomeHeroBackdropTokens.bottomAlphas.last, 1.0);
    expect(HomeHeroBackdropTokens.narrowBottomStops.last, 1.0);
    expect(HomeHeroBackdropTokens.narrowBottomAlphas.last, 1.0);
  });
}
