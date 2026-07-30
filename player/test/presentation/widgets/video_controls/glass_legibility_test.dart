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
//     only. That shadow is implemented in `_ScrubberRow`
//     (playback_chrome.dart, outside this file's scope), but its
//     contribution is modeled here so the combined fill+shadow contract is
//     what's actually verified, not fill in isolation pretending to carry a
//     job it can't.
//   - CenterPlayButton (mobile's centre play/pause glyph) has no fill behind
//     it at all — it paints directly on live video — so its shadow alone has
//     to carry SC 1.4.11 against a worst-case bright frame. Modeled
//     separately below, over opaque white rather than the panel's fill.
//
// A whole-branch review found this file modeled the timecode's foreground as
// fully OPAQUE white even though the color that shipped was translucent
// (white @ ~0.55) — the test asserted 10.68:1 while the real composited
// pixel measured 4.4967:1, UNDER the 4.5 floor it claimed to certify. Two
// things compounded: an earlier handoff asked for the remaining-time label to
// be raised to match elapsed's full-white treatment, and delivery instead
// dimmed *both* labels to 0.55; and this file, unlike `pill_legibility_test
// .dart` (written after it, for the same translucent-text problem on the top
// pills), never composited the text's own alpha on top of the shadowed
// background — it modeled the foreground as if `Icon`'s opaque-glyph
// assumption also held for text, which it doesn't once a color has partial
// alpha. Fixed on both sides: `_ScrubberRow._timeStyle.color` is now fully
// opaque `Colors.white` (honouring the original handoff), and
// `_contrastWithShadow`/`_minShadowedContrast` below now composite an
// explicit `textAlpha` on top of the shadowed background — following
// `pill_legibility_test.dart`'s `_compositeOver` method — so this test
// measures what actually ships rather than assuming an opaque glyph.
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
// end, and NOT a flat fill. If row 2 fails, the fix is the shadow (in
// `_ScrubberRow`), not more fill — raising fill enough to carry 4.5:1 on its
// own pushes the dense end back at or above DepthTokens.glassLegibilityFloor,
// which is the flat-slab defect this redesign exists to remove.

import 'dart:math' as math;

import 'package:flutter/material.dart' show Color, Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/video_controls/center_play_button.dart';
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

/// Contrast between an assumed-opaque white foreground and (r, g, b).
double _contrastWithWhite(int r, int g, int b) {
  final bg = _luminance(r, g, b);
  return (1.0 + 0.05) / (bg + 0.05);
}

/// General WCAG contrast between two arbitrary colours, lighter over darker
/// (order-independent) — needed once the foreground is no longer assumed
/// opaque white, e.g. once a shadow and a translucent text colour are both
/// composited on top of the fill.
double _contrast(int fgR, int fgG, int fgB, int bgR, int bgG, int bgB) {
  final fg = _luminance(fgR, fgG, fgB);
  final bg = _luminance(bgR, bgG, bgB);
  final lighter = math.max(fg, bg);
  final darker = math.min(fg, bg);
  return (lighter + 0.05) / (darker + 0.05);
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

/// Composites [overlay] at [overlayAlpha] on top of an existing (r, g, b)
/// background — used both for painting a shadow behind text/a glyph and for
/// painting a (possibly translucent) foreground on top of whatever is behind
/// it. Mirrors `pill_legibility_test.dart`'s helper of the same name.
(int, int, int) _compositeOver(
  (int, int, int) bg,
  Color overlay,
  double overlayAlpha,
) {
  final (br, bgG, bb) = bg;
  int channel(int background, double overlayComponent01) =>
      (background * (1 - overlayAlpha) +
              overlayComponent01 * 255 * overlayAlpha)
          .round();
  return (
    channel(br, overlay.r),
    channel(bgG, overlay.g),
    channel(bb, overlay.b),
  );
}

double _contrastFillOnly(Color tint, double alpha) {
  final (r, g, b) = _overWhite(tint, alpha);
  return _contrastWithWhite(r, g, b);
}

/// Contrast of a (possibly translucent) text colour against [tint] at
/// [alpha], with an additional [shadowColor] text-shadow layer at
/// [shadowAlpha] composited underneath it (see file comment: the shadow is
/// modeled as a flat layer at its nominal alpha, an approximation of a real
/// blurred shadow's falloff).
///
/// [textColor]/[textAlpha] are composited *on top of* the shadowed
/// background, and the returned contrast is between that final pixel and the
/// shadowed background itself — not against an assumed-opaque foreground —
/// so a translucent [textColor] (e.g. white at less than full alpha) reduces
/// the measured contrast exactly the way it would on screen. This is the
/// fix for the drift this file's header describes: previously this always
/// assumed an opaque foreground regardless of what actually shipped.
double _contrastWithShadow(
  Color tint,
  double alpha,
  Color shadowColor,
  double shadowAlpha,
  Color textColor,
  double textAlpha,
) {
  final bg = _overWhite(tint, alpha);
  final shaded = _compositeOver(bg, shadowColor, shadowAlpha);
  final fg = _compositeOver(shaded, textColor, textAlpha);
  return _contrast(fg.$1, fg.$2, fg.$3, shaded.$1, shaded.$2, shaded.$3);
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

/// Minimum fill+shadow(+text-alpha) contrast sampled at 1px steps from
/// [topY] to [bottomY] (inclusive) of a [panelHeight]-tall panel.
double _minShadowedContrast(
  double topY,
  double bottomY,
  double panelHeight,
  Color shadowColor,
  double shadowAlpha,
  Color textColor,
  double textAlpha,
) {
  var worst = double.infinity;
  for (var y = topY; y <= bottomY; y += 1) {
    final c = _contrastWithShadow(
      DepthTokens.playerChromeTint,
      _alphaAtFraction(y / panelHeight),
      shadowColor,
      shadowAlpha,
      textColor,
      textAlpha,
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

  // The shadow this test assumes for the row-2 timecodes — matches
  // `_ScrubberRow._timeStyle` in playback_chrome.dart exactly. Modest and
  // targeted: text only, no offset, small blur. (Blur radius doesn't feed
  // the contrast model below — it governs how the shadow diffuses spatially,
  // not its nominal alpha directly behind the glyph — but is recorded here
  // as part of the spec.)
  const timecodeShadowColor = Colors.black;
  const timecodeShadowAlpha = 0.6;
  const timecodeShadowBlurRadius = 4.0;

  // The timecode's own text colour/alpha — must match
  // `_ScrubberRow._timeStyle.color` exactly (opaque white). Kept as an
  // explicit local constant, not inferred, since `_timeStyle` is private to
  // playback_chrome.dart; this is the seam that let the color drift to a
  // translucent value under this test's nose before (see file header).
  const timecodeTextColor = Colors.white;
  const timecodeTextAlpha = 1.0;

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
    'modeled shadow, across the full text band — the text itself must ship '
    'fully opaque (see this file\'s header) for this margin to hold',
    () {
      final worst = _minShadowedContrast(
        timecodeTop,
        timecodeBottom,
        panelHeight,
        timecodeShadowColor,
        timecodeShadowAlpha,
        timecodeTextColor,
        timecodeTextAlpha,
      );
      expect(
        worst,
        greaterThanOrEqualTo(4.5),
        reason: 'Worst-case row-2 timecode contrast was $worst:1 with fill + '
            'a black @ $timecodeShadowAlpha, ${timecodeShadowBlurRadius}px '
            'shadow modeled in, text at alpha $timecodeTextAlpha (WCAG SC '
            '1.4.3 text floor is 4.5:1). `_ScrubberRow._timeStyle` must '
            'apply this exact shadow AND keep its color fully opaque; do '
            'not compensate with more fill.',
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

  test(
    'CenterPlayButton icon clears WCAG non-text contrast (3:1) against a '
    'worst-case bright (pure white) video frame — unlike row 1, no glass '
    'fill sits behind this glyph (it paints directly on video), so its '
    'shadow alone has to carry the floor',
    () {
      final shadow = CenterPlayButton.glyphShadow;
      final shaded = _overWhite(shadow.color, shadow.color.a);
      final contrast = _contrastWithWhite(shaded.$1, shaded.$2, shaded.$3);
      expect(
        contrast,
        greaterThanOrEqualTo(3.0),
        reason: 'Worst-case CenterPlayButton contrast against a pure-white '
            'frame was $contrast:1 (WCAG SC 1.4.11 non-text floor is 3:1). '
            'This glyph has no backing glass panel — `ControlButton`\'s '
            '"no per-glyph shadow" rule does not apply here. Strengthen '
            'CenterPlayButton.glyphShadow, do not remove it.',
      );
    },
  );
}
