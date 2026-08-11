// U8 — contrast and performance verification (plan R3, R11; AE1).
//
// Contrast is asserted computably below: the dark scrim composited over
// worst-case bright (white) artwork must keep primary text at WCAG AAA (>=7:1)
// and secondary text at WCAG AA body (>=4.5:1). With the tuned
// `AmbientBackdropScrim.baseDim`, the effective background over white artwork is
// ~rgb(40,40,41): primary ~12.8:1, secondary ~5.1:1. Real artwork (non-white,
// blurred) yields higher contrast, so these are conservative lower bounds.
//
// Frame-rate / scroll performance is MANUAL and cannot run in this headless
// unit-test environment (no CanvasKit browser). Procedure to run by hand:
//   1. `./dev up -d` then open http://localhost:4000/player in Chrome.
//   2. Build/serve the web target (CanvasKit) and open Chrome DevTools
//      Performance panel (or Flutter DevTools > Performance, "Frame rendering").
//   3. Record while scrolling (a) the Home screen with the hero parallax and
//      (b) a dense grid (e.g. Movies/Recently Added) end-to-end.
//   4. Confirm no sustained frame drops below 60fps attributable to the
//      backdrop, sheen, or glass. The backdrop is a pre-blurred ImageFiltered
//      layer (not a live full-screen BackdropFilter behind scroll); each
//      blur/sheen region is wrapped in a RepaintBoundary.
// No fabricated frame numbers are recorded here — this requires manual browser
// profiling.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/ambient_backdrop.dart';

/// WCAG relative luminance of an opaque [color].
double _relativeLuminance(Color color) {
  double channel(double c) {
    final s = c; // already 0..1
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4) as double;
  }

  final r = channel(color.r);
  final g = channel(color.g);
  final b = channel(color.b);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// WCAG contrast ratio between two opaque colors.
double _contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

/// Alpha-composite [fg] (with its own alpha) over an opaque [bg].
Color _composite(Color fg, Color bg) {
  final a = fg.a;
  return Color.from(
    alpha: 1.0,
    red: fg.r * a + bg.r * (1 - a),
    green: fg.g * a + bg.g * (1 - a),
    blue: fg.b * a + bg.b * (1 - a),
  );
}

void main() {
  // Worst case for contrast: a fully bright (white) backdrop artwork. The dark
  // scrim composited over it sets the effective background text sits on.
  const brightArtwork = Color(0xFFFFFFFF);

  // Both the base colour and the alpha are read off the widget, so this can no
  // longer drift from what AmbientBackdropScrim actually paints. The previous
  // version named AppColors.background here while the widget painted a navy
  // literal, and stayed green throughout.
  final scrim = AmbientBackdropScrim.baseColor.withValues(
    alpha: AmbientBackdropScrim.baseDim,
  );
  final effectiveBackground = _composite(scrim, brightArtwork);

  group('AmbientBackdrop scrim contrast over bright artwork', () {
    test('primary text holds a high contrast ratio (~15:1 target)', () {
      final ratio = _contrastRatio(AppColors.textPrimary, effectiveBackground);
      // Over worst-case white artwork the scrim must keep primary text strongly
      // legible. We require a comfortably-AAA ratio; the theme targets ~15:1 on
      // the flat background, and the dim keeps it well above the 7:1 AAA bar.
      expect(ratio, greaterThanOrEqualTo(7.0),
          reason: 'primary text contrast was $ratio');
    });

    test('secondary text holds an AA-large / body-legible ratio', () {
      final ratio =
          _contrastRatio(AppColors.textSecondary, effectiveBackground);
      // Secondary text targets ~7:1 on the flat theme; over worst-case bright
      // artwork it must still clear the WCAG AA 4.5:1 body-text bar.
      expect(ratio, greaterThanOrEqualTo(4.5),
          reason: 'secondary text contrast was $ratio');
    });

    test('the effective background stays dark (luminance well below mid)', () {
      // A sanity bound: the scrimmed bright artwork must read as a dark surface
      // so the cinematic look and contrast both hold.
      expect(_relativeLuminance(effectiveBackground), lessThan(0.25));
    });
  });

  // U10 — chrome legibility floor (plan R10; AE4). Glass chrome (sidebar, app
  // bars, video controls) floats over the *scrimmed* backdrop and adds its own
  // translucent fill on top, so the surface text sits on is even darker than
  // the bare scrim. We assert primary/secondary text clear the WCAG floor over
  // worst-case bright artwork behind both layers.
  group('chrome glass legibility over bright artwork (R10/AE4)', () {
    // Sidebar/control chrome: surface tint at the chrome fill opacity, over the
    // scrimmed white backdrop.
    final sidebarBg = _composite(
      AppColors.surface.withValues(alpha: DepthTokens.chromeFillOpacity),
      effectiveBackground,
    );
    // App-bar/video chrome: background tint at the chrome fill opacity.
    final barBg = _composite(
      AppColors.background.withValues(alpha: DepthTokens.chromeFillOpacity),
      effectiveBackground,
    );

    test('sidebar chrome keeps primary text comfortably AAA', () {
      expect(
        _contrastRatio(AppColors.textPrimary, sidebarBg),
        greaterThanOrEqualTo(7.0),
      );
    });

    test('sidebar chrome keeps secondary text above the AA body floor', () {
      expect(
        _contrastRatio(AppColors.textSecondary, sidebarBg),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('bar/video chrome keeps white controls strongly legible', () {
      // The video controls and app-bar icons/text are white-on-chrome.
      expect(
        _contrastRatio(const Color(0xFFFFFFFF), barBg),
        greaterThanOrEqualTo(7.0),
      );
    });

    test('the chrome fill clears the configured legibility floor', () {
      expect(
        DepthTokens.chromeFillOpacity,
        greaterThanOrEqualTo(DepthTokens.glassLegibilityFloor),
      );
    });
  });

  // The invariant the old hardcoded navy violated. Mirrors the
  // `playerChromeTint` test in depth_tokens_test.dart: a scrim carrying a hue
  // drains the blurred poster behind it toward that hue instead of letting the
  // artwork's own colour through.
  group('AmbientBackdrop scrim base colour', () {
    test('is hueless so it does not drain colour from the artwork', () {
      final c = AmbientBackdropScrim.baseColor;
      const tolerance = 2 / 255;
      expect((c.b - c.r).abs(), lessThanOrEqualTo(tolerance),
          reason: 'blue cast of ${(c.b - c.r).abs()}');
      expect((c.g - c.r).abs(), lessThanOrEqualTo(tolerance),
          reason: 'green cast of ${(c.g - c.r).abs()}');
    });
  });
}
