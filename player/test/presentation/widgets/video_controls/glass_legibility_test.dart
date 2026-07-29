// The player glass fills with an asymmetric gradient: dense at the top,
// where the control row sits, so white glyphs stay legible; sheer at the
// bottom, where only the scrubber's white track sits and genuine
// transparency matters more.
//
// Two different WCAG 2.1 success criteria apply here, and this test measures
// each against the right one, across the actual band each occupies (not a
// single hand-picked point):
//   - Row 1 (volume/transport/secondary) is icons — graphical objects, not
//     text — so SC 1.4.11 (Non-text Contrast) applies: 3:1, checked with
//     fill alone, since icons get no text-shadow treatment (see
//     DepthTokens.playerChromeFillTopAlpha's doc comment for why: a blanket
//     shadow on every glyph is the muddy look this redesign removes).
//   - Row 2's timecodes are genuine small text (12-13px), so the stricter
//     SC 1.4.3 (Contrast (Minimum)) applies: 4.5:1. Fill alone cannot carry
//     that from under DepthTokens.glassLegibilityFloor, so — per direction —
//     the gap is closed with a small, targeted text shadow on the timecodes
//     only. That shadow is implemented in Task 12's `_ScrubberRow` (outside
//     this file's scope), but its contribution is modeled here so the
//     combined fill+shadow contract is what's actually verified, not fill in
//     isolation pretending to carry a job it can't.
//
// This is a plain, analytical `test()`, not a `testWidgets()` rendering test
// — and the fill/blur/saturation part of that is exact here, not an
// approximation. Over a spatially uniform white backdrop, both of
// GlassSurface.playerChrome's live transforms are the identity function:
//   - Gaussian blur of a constant field returns the same constant field (no
//     edge effects, since the backdrop this test models is uniform far
//     beyond the blur radius in every direction).
//   - The saturation ColorFilter matrix (`saturationColorMatrix`) preserves
//     luminance by construction: for a channel-equal colour like white
//     (r=g=b=1), every row of the matrix sums to `(1-s)*(lr+lg+lb) + s = 1`
//     regardless of `s` (lr+lg+lb == 1 by definition of the Rec.709
//     coefficients), so it maps white to white exactly, for any saturation
//     multiplier.
// So the composite this test needs for the fill contribution — tint at some
// alpha, painted over a live-blurred, saturated white backdrop — is
// *identical* to tint at that alpha painted directly over flat white: a
// closed-form src-over blend, computed below, not a rendering shortcut. This
// equivalence assumes Flutter composites src-over in sRGB-encoded space
// (gamma-encoded channel values blended directly), which is what it does —
// it is not a colour-space-agnostic fact in general: the same alpha blended
// in *linear* light would produce a materially different (generally
// brighter-reading) result. The shadow contribution below is a modeling
// approximation, not an equivalence: a real blurred text-shadow's coverage
// falls off with distance from the glyph, whereas this models it as a flat
// extra layer at its nominal alpha directly behind the glyph — reasonable at
// zero offset with a small blur radius, but not pixel-exact the way the fill
// math above is.
//
// A prior version of this test rendered the real widget tree and read pixels
// back via RenderRepaintBoundary.toImage()/Image.toByteData(). At one
// candidate token set it measured 4.550376972623228 against this file's
// closed-form calculation of 4.5 exactly — a ~1.1% difference in the
// contrast figure itself (not "~0.25%": that smaller figure was the pixel
// quantization delta, e.g. 1 LSB out of a channel value near 128, not the
// resulting contrast delta). That approach was dropped because
// Image.toByteData() hangs in flutter_test's own post-body teardown in this
// project's nix/macOS toolchain — reproduced with a bare ColoredBox with no
// relation to ChromePanel — which is a real environment defect, not a reason
// to trust this analytical version any less.
//
// If row 1 fails, the fix is more *dense*-end gradient weight — raise
// DepthTokens.playerChromeFillTopAlpha in 0.04 increments — NOT the sheer
// end, and NOT a flat fill. If row 2 fails, the fix is the shadow (in Task
// 12's `_ScrubberRow`), not more fill — raising fill enough to carry 4.5:1
// on its own pushes the dense end back at or above
// DepthTokens.glassLegibilityFloor, which is the flat-slab defect this
// redesign exists to remove.

import 'dart:math' as math;

import 'package:flutter/material.dart' show Color, Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/video_controls/chrome_panel.dart';

/// WCAG relative luminance.
double _luminance(int r, int g, int b) {
  double channel(int v) {
    final s = v / 255.0;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

double _contrastWithWhite(int r, int g, int b) {
  final bg = _luminance(r, g, b);
  return (1.0 + 0.05) / (bg + 0.05);
}

/// Composites [tint] at [alpha] over opaque white and returns the resulting
/// channels (0-255) — the closed-form equivalent of GlassSurface.playerChrome's
/// fill over a solid white backdrop (see file comment for why blur/saturation
/// drop out of that equivalence).
(int, int, int) _overWhite(Color tint, double alpha) {
  int channel(double tintComponent01) =>
      (255 * (1 - alpha) + tintComponent01 * 255 * alpha).round();
  return (channel(tint.r), channel(tint.g), channel(tint.b));
}

double _contrastFillOnly(Color tint, double alpha) {
  final (r, g, b) = _overWhite(tint, alpha);
  return _contrastWithWhite(r, g, b);
}

/// Contrast of white text against [tint] at [alpha], with an additional
/// [shadowColor] text-shadow layer at [shadowAlpha] composited on top (see
/// file comment: modeled as a flat layer at its nominal alpha, an
/// approximation of a real blurred shadow's falloff).
double _contrastWithShadow(
  Color tint,
  double alpha,
  Color shadowColor,
  double shadowAlpha,
) {
  final (r, g, b) = _overWhite(tint, alpha);
  int shaded(int background, double shadowComponent01) =>
      (background * (1 - shadowAlpha) + shadowComponent01 * 255 * shadowAlpha)
          .round();
  return _contrastWithWhite(
    shaded(r, shadowColor.r),
    shaded(g, shadowColor.g),
    shaded(b, shadowColor.b),
  );
}

/// Fill alpha at vertical fraction [frac] (0 = panel top, 1 = panel bottom)
/// of the top-to-bottom gradient.
double _alphaAtFraction(double frac) =>
    DepthTokens.playerChromeFillTopAlpha +
    (DepthTokens.playerChromeFillBottomAlpha -
            DepthTokens.playerChromeFillTopAlpha) *
        frac;

/// Minimum fill-only contrast sampled at 1px steps from [topY] to [bottomY]
/// (inclusive) of a [panelHeight]-tall panel.
double _minFillOnlyContrast(double topY, double bottomY, double panelHeight) {
  var worst = double.infinity;
  for (var y = topY; y <= bottomY; y += 1) {
    final c = _contrastFillOnly(
      DepthTokens.playerChromeTint,
      _alphaAtFraction(y / panelHeight),
    );
    if (c < worst) worst = c;
  }
  return worst;
}

/// Minimum fill+shadow contrast sampled at 1px steps from [topY] to [bottomY]
/// (inclusive) of a [panelHeight]-tall panel.
double _minShadowedContrast(
  double topY,
  double bottomY,
  double panelHeight,
  Color shadowColor,
  double shadowAlpha,
) {
  var worst = double.infinity;
  for (var y = topY; y <= bottomY; y += 1) {
    final c = _contrastWithShadow(
      DepthTokens.playerChromeTint,
      _alphaAtFraction(y / panelHeight),
      shadowColor,
      shadowAlpha,
    );
    if (c < worst) worst = c;
  }
  return worst;
}

void main() {
  // --- Panel geometry, derived from ChromePanel's own public constants plus
  // representative row/glyph dimensions (ChromePanel doesn't own row content
  // sizing, so these mirror what the rest of this test suite already uses:
  // a 48px transport row and a 32px scrubber row).
  const row1Height = 48.0;
  const row2Height = 32.0;
  const panelHeight = ChromePanel.verticalPadding * 2 +
      row1Height +
      ChromePanel.rowGap +
      row2Height;

  final row1Top = ChromePanel.verticalPadding;
  final row1Bottom = row1Top + row1Height;
  final row2Top = row1Bottom + ChromePanel.rowGap;

  // The tallest icon glyph actually used in row 1 is TransportSurface's
  // play/pause button (`iconSize: 30`, in a `size: 48` button matching the
  // row's own height) — the worst case, since a taller glyph reaches closer
  // to the row's edges where fill is sheerest.
  const controlGlyphHeight = 30.0;
  final controlGlyphTop = row1Top + (row1Height - controlGlyphHeight) / 2;
  final controlGlyphBottom = controlGlyphTop + controlGlyphHeight;

  // The row-2 timecodes are 12-13px text, vertically centred in the row.
  const timecodeHeight = 13.0;
  final timecodeTop = row2Top + (row2Height - timecodeHeight) / 2;
  final timecodeBottom = timecodeTop + timecodeHeight;

  // The shadow this test assumes for the row-2 timecodes — hand this exact
  // spec to Task 12's `_ScrubberRow`. Modest and targeted: text only, no
  // offset, small blur. (Blur radius doesn't feed the contrast model below —
  // it governs how the shadow diffuses spatially, not its nominal alpha
  // directly behind the glyph — but is recorded here as part of the spec.)
  const timecodeShadowColor = Colors.black;
  const timecodeShadowAlpha = 0.6;
  const timecodeShadowBlurRadius = 4.0;

  test(
    'row 1 icons clear WCAG non-text contrast (3:1) from fill alone, '
    'across the full icon band — no shadow',
    () {
      final worst = _minFillOnlyContrast(
        controlGlyphTop,
        controlGlyphBottom,
        panelHeight,
      );
      expect(
        worst,
        greaterThanOrEqualTo(3.0),
        reason: 'Worst-case row-1 icon contrast was $worst:1 over a white '
            'backdrop (fill alone, WCAG SC 1.4.11 non-text floor is 3:1). '
            'Raise DepthTokens.playerChromeFillTopAlpha — never add a '
            'shadow to icons.',
      );
    },
  );

  test(
    'row 2 timecodes clear WCAG text contrast (4.5:1) with fill + the '
    'modeled shadow, across the full text band',
    () {
      final worst = _minShadowedContrast(
        timecodeTop,
        timecodeBottom,
        panelHeight,
        timecodeShadowColor,
        timecodeShadowAlpha,
      );
      expect(
        worst,
        greaterThanOrEqualTo(4.5),
        reason: 'Worst-case row-2 timecode contrast was $worst:1 with fill + '
            'a black @ $timecodeShadowAlpha, ${timecodeShadowBlurRadius}px '
            'shadow modeled in (WCAG SC 1.4.3 text floor is 4.5:1). Task 12 '
            'must apply this shadow spec to the timecodes; do not compensate '
            'with more fill.',
      );
    },
  );

  test(
    'row 2 timecodes do NOT clear 4.5:1 from fill alone — the shadow is '
    'load-bearing, not redundant',
    () {
      final worst = _minFillOnlyContrast(
        timecodeTop,
        timecodeBottom,
        panelHeight,
      );
      expect(
        worst,
        lessThan(4.5),
        reason: 'Fill alone measured $worst:1 at the timecodes, which is '
            '>= 4.5:1 without the shadow modeled in. That means either the '
            'fill token crept back up (defeating the transparency this '
            'redesign buys) or this test stopped exercising the shadow '
            'requirement — investigate before treating this as good news.',
      );
    },
  );
}
