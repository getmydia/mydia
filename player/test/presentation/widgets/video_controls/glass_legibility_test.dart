// The player glass fills with an asymmetric gradient: dense at the top,
// where the control row sits, so white glyphs stay legible; sheer at the
// bottom, where only the scrubber's white track sits and genuine
// transparency matters more. This measures the actual worst-case contrast at
// the control row against a fully blown-out white backdrop.
//
// This is a plain, analytical `test()`, not a `testWidgets()` rendering test
// — and that is exact here, not an approximation. Over a spatially uniform
// white backdrop, both of GlassSurface.playerChrome's live transforms are the
// identity function:
//   - Gaussian blur of a constant field returns the same constant field (no
//     edge effects, since the backdrop this test models is uniform far
//     beyond the blur radius in every direction).
//   - The saturation ColorFilter matrix (`saturationColorMatrix`) preserves
//     luminance by construction: for a channel-equal colour like white
//     (r=g=b=1), every row of the matrix sums to `(1-s)*(lr+lg+lb) + s = 1`
//     regardless of `s` (lr+lg+lb == 1 by definition of the Rec.709
//     coefficients), so it maps white to white exactly, for any saturation
//     multiplier.
// So the composite this test needs — tint at some alpha, painted over a
// live-blurred, saturated white backdrop — is *identical* to tint at that
// alpha painted directly over flat white: a closed-form src-over blend,
// computed below, not a rendering shortcut.
//
// A prior version of this test rendered the real widget tree and read pixels
// back via RenderRepaintBoundary.toImage()/Image.toByteData(). It measured
// contrast values that matched this file's closed-form calculation to within
// ~0.25% (e.g. 4.550 rendered vs. 4.500 computed at one candidate token set)
// — the residual is 8-bit pixel quantization in the real render, not a
// modeling gap. That approach was dropped because Image.toByteData() hangs
// in flutter_test's own post-body teardown in this project's nix/macOS
// toolchain — reproduced with a bare ColoredBox with no relation to
// ChromePanel — which is a real environment defect, not a reason to trust
// this analytical version any less.
//
// If this fails, the fix is more *dense*-end gradient weight — raise
// DepthTokens.playerChromeFillTopAlpha in 0.04 increments — NOT the sheer
// end, and NOT a flat fill. See DepthTokens.playerChromeFillTopAlpha's doc
// comment for why the dense end is at the top.

import 'dart:math' as math;

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';

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

/// Contrast of white text against [tint] composited at [alpha] over opaque
/// white — the closed-form equivalent of GlassSurface.playerChrome's fill
/// over a solid white backdrop (see file comment for why blur/saturation
/// drop out of that equivalence).
double _contrastOverWhite(Color tint, double alpha) {
  int channel(double tintComponent01) =>
      (255 * (1 - alpha) + tintComponent01 * 255 * alpha).round();

  return _contrastWithWhite(
    channel(tint.r),
    channel(tint.g),
    channel(tint.b),
  );
}

void main() {
  test('white controls clear 4.5:1 over a worst-case bright backdrop', () {
    // The control row (row 1: volume/transport/secondary) sits just below
    // ChromePanel's 16px top padding, roughly centred in its own 48px-tall
    // row: (16 + 24) of a 130px panel (16 padding + 48 row1 + 18 gap + 32
    // row2 + 16 padding) ≈ 0.31 of the way down the panel, rounded to 0.30.
    const controlRowFraction = 0.30;

    final alphaAtControlRow = DepthTokens.playerChromeFillTopAlpha +
        (DepthTokens.playerChromeFillBottomAlpha -
                DepthTokens.playerChromeFillTopAlpha) *
            controlRowFraction;

    final worst = _contrastOverWhite(
      DepthTokens.playerChromeTint,
      alphaAtControlRow,
    );

    expect(
      worst,
      greaterThanOrEqualTo(4.5),
      reason: 'White-on-glass contrast was $worst:1 over a white backdrop, '
          'at alpha $alphaAtControlRow (${(controlRowFraction * 100).round()}%'
          ' down the panel — the control row). Raise '
          'DepthTokens.playerChromeFillTopAlpha (the dense end) — do not '
          'raise the sheer end and do not flatten the gradient.',
    );
  });
}
