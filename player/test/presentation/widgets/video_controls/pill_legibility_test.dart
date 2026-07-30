// ChromeTopBar's three pills (Task 11) reuse GlassSurface.playerChrome — the
// exact same material `glass_legibility_test.dart` measures for ChromePanel —
// but at a very different geometry: 36px tall, versus ChromePanel's ~130px.
// The gradient's density still runs from DepthTokens.playerChromeFillTopAlpha
// (dense) to playerChromeFillBottomAlpha (sheer) over that whole span, so
// squeezing it into 36px compresses the same ramp into a much shorter
// distance, and pill text sits across a meaningful fraction of that ramp
// rather than in a band pinned near the dense end.
//
// This file follows the exact analytical method established in
// glass_legibility_test.dart (see that file's header for the full
// justification): over a spatially uniform white backdrop, GlassSurface
// .playerChrome's blur and saturation are both the identity transform, so the
// fill's contribution is an exact closed-form src-over blend of
// DepthTokens.playerChromeTint over white — not a rendering approximation.
//
// One difference from that file's model: ChromePanel's row-1 controls are
// checked as *icons* (opaque, full-luminance foreground assumed) against SC
// 1.4.11 (3:1). The pill text here is genuine small text — SC 1.4.3 (4.5:1)
// applies — and, critically, it is painted at `white @ 0.80`, not opaque
// white. A translucent foreground composites with whatever sits behind it,
// so this file's contrast model composites the text's own alpha on top of
// the (optionally shadowed) fill, rather than assuming an opaque glyph the
// way the panel's icon check does.
//
// Measured (this file's own tests, run standalone): fill alone gives
// 2.4671976733802308:1 across the text band — badly under both 3:1 and
// 4.5:1 — while fill + a black @ 0.6 shadow gives 7.755850943957899:1,
// comfortably above the 4.5:1 text floor. GlassPill.textShadow implements
// that exact shadow spec.
import 'dart:math' as math;

import 'package:flutter/material.dart' show Color, Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/video_controls/chrome_top_bar.dart';

double _luminance(int r, int g, int b) {
  double channel(int v) {
    final s = v / 255.0;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

double _contrast(int fgR, int fgG, int fgB, int bgR, int bgG, int bgB) {
  final fg = _luminance(fgR, fgG, fgB);
  final bg = _luminance(bgR, bgG, bgB);
  final lighter = math.max(fg, bg);
  final darker = math.min(fg, bg);
  return (lighter + 0.05) / (darker + 0.05);
}

/// Composites [tint] at [alpha] over opaque white — the closed-form
/// equivalent of GlassSurface.playerChrome's fill over a solid white backdrop
/// (see file comment).
(int, int, int) _overWhite(Color tint, double alpha) {
  int channel(double tintComponent01) =>
      (255 * (1 - alpha) + tintComponent01 * 255 * alpha).round();
  return (channel(tint.r), channel(tint.g), channel(tint.b));
}

/// Composites [overlay] at [overlayAlpha] on top of an existing (r, g, b)
/// background — used both for painting the shadow behind the text and for
/// painting the translucent text itself on top of whatever is behind it.
(int, int, int) _compositeOver(
    (int, int, int) bg, Color overlay, double overlayAlpha) {
  final (br, bg_, bb) = bg;
  int channel(int background, double overlayComponent01) =>
      (background * (1 - overlayAlpha) +
              overlayComponent01 * 255 * overlayAlpha)
          .round();
  return (
    channel(br, overlay.r),
    channel(bg_, overlay.g),
    channel(bb, overlay.b),
  );
}

/// Fill alpha at vertical fraction [frac] (0 = pill top, 1 = pill bottom) of
/// the top-to-bottom gradient GlassSurface.playerChrome paints across
/// whatever height it's given — here, the pill's full [GlassPill.height].
double _alphaAtFraction(double frac) =>
    DepthTokens.playerChromeFillTopAlpha +
    (DepthTokens.playerChromeFillBottomAlpha -
            DepthTokens.playerChromeFillTopAlpha) *
        frac;

// The pill text spec (Task 11): 13px, white @ 0.80, vertically centered in
// the 36px pill via Center (no vertical padding). Matches the convention
// glass_legibility_test.dart already uses of treating font size as a stand-in
// for the glyph's occupied pixel height.
const _textColor = Colors.white;
const _textAlpha = 0.80;
const _textHeight = 13.0;
final _textTop = (GlassPill.height - _textHeight) / 2;
final _textBottom = _textTop + _textHeight;

// The shadow spec this file's measurement leads to (see test bodies below) —
// same alpha as Task 10 handed to Task 12's timecodes (black @ 0.6), applied
// here to the pill text. Blur radius doesn't feed the contrast model (it
// governs spatial falloff, not the nominal alpha directly behind the glyph)
// but is recorded for the implementation to match.
const pillTextShadowColor = Colors.black;
const pillTextShadowAlpha = 0.6;
const pillTextShadowBlurRadius = 3.0;

double _minContrastNoShadow(double topY, double bottomY) {
  var worst = double.infinity;
  for (var y = topY; y <= bottomY; y += 0.5) {
    final bg = _overWhite(
      DepthTokens.playerChromeTint,
      _alphaAtFraction(y / GlassPill.height),
    );
    final fg = _compositeOver(bg, _textColor, _textAlpha);
    final c = _contrast(fg.$1, fg.$2, fg.$3, bg.$1, bg.$2, bg.$3);
    if (c < worst) worst = c;
  }
  return worst;
}

double _minContrastWithShadow(double topY, double bottomY) {
  var worst = double.infinity;
  for (var y = topY; y <= bottomY; y += 0.5) {
    final bg = _overWhite(
      DepthTokens.playerChromeTint,
      _alphaAtFraction(y / GlassPill.height),
    );
    final shaded = _compositeOver(bg, pillTextShadowColor, pillTextShadowAlpha);
    final fg = _compositeOver(shaded, _textColor, _textAlpha);
    final c = _contrast(fg.$1, fg.$2, fg.$3, shaded.$1, shaded.$2, shaded.$3);
    if (c < worst) worst = c;
  }
  return worst;
}

void main() {
  test(
    'pill text at white @ 0.80 does NOT clear WCAG text contrast (4.5:1) '
    'from fill alone — the 36px pill height compresses the gradient too far '
    'for the panel-tuned tokens to carry it unaided',
    () {
      final worst = _minContrastNoShadow(_textTop, _textBottom);
      expect(
        worst,
        lessThan(4.5),
        reason: 'Fill-only contrast measured $worst:1 across the pill text '
            'band. This is expected to fail — it demonstrates the pill '
            'geometry needs a targeted text treatment (see the other test '
            'in this file), not that the fill token should be raised '
            '(raising it back toward the panel-tuned density would push '
            'DepthTokens.playerChromeFillTopAlpha at/above '
            'glassLegibilityFloor and erase the transparency this material '
            'is supposed to buy).',
      );
    },
  );

  test(
    'pill text clears WCAG text contrast (4.5:1) once a targeted shadow '
    '(black @ 0.6) backs it, across the full text band',
    () {
      final worst = _minContrastWithShadow(_textTop, _textBottom);
      expect(
        worst,
        greaterThanOrEqualTo(4.5),
        reason: 'Worst-case pill text contrast was $worst:1 with fill + a '
            'black @ $pillTextShadowAlpha shadow modeled in (WCAG SC 1.4.3 '
            'floor is 4.5:1). GlassPill must apply this shadow to its text.',
      );
    },
  );
}
