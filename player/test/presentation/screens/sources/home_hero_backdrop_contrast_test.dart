// The Home hero's backdrop paints artwork behind its title, chips and
// overview. This composites the real black scrim stops over worst-case white
// artwork and asserts the text clears WCAG AA (4.5:1).
//
// Only the left-to-right scrim is credited. The top scrim is the same black,
// so it can only raise the opacity over the text, never lower it. The
// artwork's own fade mask only ever reveals the shell's dark backdrop, which
// is darker than white art, so it cannot lower contrast either.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/breakpoints.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/screens/sources/source_home_hero.dart';
import 'package:player/presentation/screens/sources/source_home_hero_backdrop.dart';

import '../../../test_utils/osd_contrast.dart';

const _white = Color(0xFFFFFFFF);
const _aa = 4.5;

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

void main() {
  const poster = SourceHomeHero.posterSize;
  const gap = 36.0;
  const maxText = 560.0;

  test('text clears 4.5:1 at the info column\'s right edge over white art', () {
    var worstTitle = double.infinity;
    var worstOverview = double.infinity;
    var worstChip = double.infinity;
    for (final window in const [
      900.0,
      1000.0,
      1280.0,
      1440.0,
      1920.0,
      2560.0
    ]) {
      for (final pinned in const [false, true]) {
        // The backdrop spans the window, under the rail; the hero's column
        // starts at the rail's footprint and its padding follows the window.
        final inset = Breakpoints.railContentInset(pinned: pinned);
        final backdropWidth = window;
        final padding = window >= Breakpoints.desktop ? 32.0 : 24.0;
        final gradient = HomeHeroBackdropTokens.leftGradient(
          width: backdropWidth,
          inset: inset,
          padding: padding,
          posterSize: poster,
          gap: gap,
          maxTextWidth: maxText,
        );
        final textRight = HomeHeroBackdropTokens.textRightEdge(
          width: backdropWidth,
          inset: inset,
          padding: padding,
          posterWidth: poster.width,
          gap: gap,
          maxTextWidth: maxText,
        );
        // Opacity falls left to right, so the right edge is the worst point
        // under any glyph.
        final alpha = _alphaAt(gradient, textRight / backdropWidth);
        final bg = compositeOver(Colors.black.withValues(alpha: alpha), _white);

        final title = contrastRatio(Palettes.projectionBooth.textPrimary, bg);
        final pureWhite = contrastRatio(_white, bg);
        final overviewColor = compositeOver(
          Palettes.projectionBooth.textPrimary.withValues(alpha: 0.78),
          bg,
        );
        final overview = contrastRatio(overviewColor, bg);
        final chipBg = compositeOver(_white.withValues(alpha: 0.12), bg);
        final chip =
            contrastRatio(Palettes.projectionBooth.textPrimary, chipBg);

        final where = 'window $window, pinned $pinned';
        expect(title, greaterThanOrEqualTo(_aa), reason: 'title, $where');
        expect(pureWhite, greaterThanOrEqualTo(_aa),
            reason: 'white text, $where');
        expect(overview, greaterThanOrEqualTo(_aa), reason: 'overview, $where');
        expect(chip, greaterThanOrEqualTo(_aa), reason: 'chips, $where');
        worstTitle = worstTitle < title ? worstTitle : title;
        worstOverview = worstOverview < overview ? worstOverview : overview;
        worstChip = worstChip < chip ? worstChip : chip;
      }
    }
    debugPrint('worst over white art: title ${worstTitle.toStringAsFixed(2)}, '
        'overview ${worstOverview.toStringAsFixed(2)}, '
        'chips ${worstChip.toStringAsFixed(2)}');
  });

  test('the scrim is weakest exactly at the text and is gone past it', () {
    final g = HomeHeroBackdropTokens.leftGradient(
      width: 1328,
      padding: 32,
      posterSize: poster,
      gap: gap,
      maxTextWidth: maxText,
    );
    final right = HomeHeroBackdropTokens.textRightEdge(
      width: 1328,
      padding: 32,
      posterWidth: poster.width,
      gap: gap,
      maxTextWidth: maxText,
    );
    expect(_alphaAt(g, right / 1328),
        closeTo(HomeHeroBackdropTokens.textAlpha, 1e-9));
    expect(_alphaAt(g, 1.0), lessThan(0.05),
        reason: 'the art is clear on the right');
  });

  test('the art is opaque until the fade starts and gone at the bottom', () {
    final (stops, alphas) = HomeHeroBackdropTokens.maskCurve;
    expect(stops.first, 0.0);
    expect(alphas.first, 1.0);
    expect(stops.last, 1.0);
    expect(alphas.last, 0.0);
    final start = stops.indexOf(HomeHeroBackdropTokens.fadeStart);
    expect(alphas[start], 1.0);
    for (var i = 1; i < alphas.length; i++) {
      expect(alphas[i], lessThanOrEqualTo(alphas[i - 1]),
          reason: 'the fade never steps back up');
      expect(stops[i], greaterThanOrEqualTo(stops[i - 1]));
    }
  });
}
