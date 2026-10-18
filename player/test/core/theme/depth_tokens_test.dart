// U1 — depth/material token module (plan R1, R2, R3).
//
// Verifies the token groups expose the documented constants with the expected
// types, and that wiring the default palette into the theme keeps it
// dark-only, drives the surface hierarchy from the palette, and maps a single
// accent hue across every Material 3 accent slot (R3).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/palette.dart';

void main() {
  group('blur sigmas (R8)', () {
    test('are doubles seeded from the established 0/2/8/10/40 values', () {
      expect(DepthTokens.blurNone, 0.0);
      expect(DepthTokens.blurHoverOverlay, 2.0);
      expect(DepthTokens.blurModal, 8.0);
      expect(DepthTokens.blurChrome, 10.0);
      expect(DepthTokens.blurAmbient, 40.0);
    });
  });

  group('shadow profiles (R7)', () {
    test('expose resting + hover poster shadows with visible alpha', () {
      expect(DepthTokens.posterResting, isA<List<BoxShadow>>());
      expect(DepthTokens.posterResting, isNotEmpty);
      expect(DepthTokens.posterResting.first.color.a, greaterThan(0));
      expect(DepthTokens.chrome, isA<List<BoxShadow>>());
    });

    test('hover shadow is a deeper accent than resting, but bounded (R11)', () {
      final resting = DepthTokens.posterResting.first;
      final hover = DepthTokens.posterHover.first;
      expect(hover.color.a, greaterThan(resting.color.a));
      expect(hover.blurRadius, greaterThan(resting.blurRadius));
      // Not the prior pass's heavy 0.35 / 20 jump.
      expect(hover.color.a, lessThan(0.35));
      expect(hover.blurRadius, lessThan(20));
    });
  });

  group('rim + glass fill (R4/R10)', () {
    test('rim is a hairline light edge', () {
      expect(DepthTokens.rimWidth, 1.0);
      expect(DepthTokens.rimColor.a, greaterThan(0));
    });

    test('chrome fill opacity clears the legibility floor (R10)', () {
      expect(
        DepthTokens.chromeFillOpacity,
        greaterThanOrEqualTo(DepthTokens.glassLegibilityFloor),
      );
      expect(DepthTokens.glassLegibilityFloor, inInclusiveRange(0.0, 1.0));
    });
  });

  group('OSD material', () {
    test('fill is the neutral background tint at 0.85', () {
      expect(DepthTokens.osdTint, Palettes.projectionBooth.background);
      expect(DepthTokens.osdFillOpacity, 0.85);
      expect(
        DepthTokens.osdFillOpacity,
        greaterThan(DepthTokens.chromeFillOpacity),
      );
    });

    test('tint is neutral, so it does not drain colour from the video', () {
      final t = DepthTokens.osdTint;
      const tolerance = 2 / 255;
      expect((t.b - t.r).abs(), lessThanOrEqualTo(tolerance));
      expect((t.g - t.r).abs(), lessThanOrEqualTo(tolerance));
    });

    test('blurs at sigma 20', () {
      expect(DepthTokens.osdBlurSigma, 20.0);
    });

    test('hairline and divider are faint white', () {
      expect(DepthTokens.osdHairline, const Color(0x1AFFFFFF));
      expect(DepthTokens.osdDivider, const Color(0x14FFFFFF));
    });

    test('the pill shadow is smaller and lighter than the panel shadow', () {
      final panel = DepthTokens.osdShadowPanel.single;
      final pill = DepthTokens.osdShadowPill.single;
      expect(panel.blurRadius, 36);
      expect(panel.offset, const Offset(0, 10));
      expect(pill.blurRadius, lessThan(panel.blurRadius));
      expect(pill.color.a, lessThan(panel.color.a));
      expect(pill.offset.dy, lessThan(panel.offset.dy));
    });

    test('OsdElevation maps onto the shadow tokens', () {
      expect(OsdElevation.panel.shadows, DepthTokens.osdShadowPanel);
      expect(OsdElevation.pill.shadows, DepthTokens.osdShadowPill);
      expect(OsdElevation.none.shadows, isEmpty);
    });

    test('exposes panel, pill and sheet radii', () {
      expect(DepthTokens.radiusOsdPanel, 16.0);
      expect(DepthTokens.radiusOsdPill, 18.0);
      expect(DepthTokens.radiusOsdSheet, 20.0);
    });
  });

  group('motion (R11)', () {
    test('exposes durations and curves', () {
      expect(DepthTokens.motionFast, isA<Duration>());
      expect(DepthTokens.motionMedium, isA<Duration>());
      expect(DepthTokens.motionSlow, isA<Duration>());
      expect(DepthTokens.curveStandard, isA<Curve>());
      expect(DepthTokens.curveEmphasized, isA<Curve>());
      // Ordered fast < medium < slow.
      expect(DepthTokens.motionFast, lessThan(DepthTokens.motionMedium));
      expect(DepthTokens.motionMedium, lessThan(DepthTokens.motionSlow));
    });
  });

  group('Liquid Glass', () {
    test('blur, edge, refraction and rim are positive', () {
      expect(DepthTokens.liquidBlurSigma, greaterThan(0));
      expect(DepthTokens.liquidEdgeBand, greaterThan(0));
      expect(DepthTokens.liquidRefraction, greaterThan(0));
      expect(DepthTokens.liquidRimWidth, greaterThan(0));
    });

    test('press swells the glass', () {
      expect(DepthTokens.liquidPressScale, greaterThan(1));
    });

    test('press is brighter than hover', () {
      expect(
        DepthTokens.liquidSpecular + DepthTokens.liquidPressSpecularBoost,
        greaterThan(
          DepthTokens.liquidSpecular + DepthTokens.liquidHoverSpecularBoost,
        ),
      );
    });

    test('the resting light sits inside the surface', () {
      expect(DepthTokens.liquidLightRest.dx, inInclusiveRange(0.0, 1.0));
      expect(DepthTokens.liquidLightRest.dy, inInclusiveRange(0.0, 1.0));
    });

    test('tint opacities are valid and the contrast boost is positive', () {
      for (final opacity in [
        DepthTokens.liquidChromeTintOpacity,
        DepthTokens.liquidModalTintOpacity,
        DepthTokens.liquidControlTintOpacity,
        DepthTokens.liquidProminentTintOpacity,
      ]) {
        expect(opacity, inInclusiveRange(0.0, 1.0));
      }
      expect(DepthTokens.liquidHighContrastTintBoost, greaterThan(0));
    });

    test('adaptive tint tokens are ordered and valid', () {
      for (final v in [
        DepthTokens.liquidChromeAdaptiveMax,
        DepthTokens.liquidModalAdaptiveMax,
        DepthTokens.liquidControlAdaptiveMax,
        DepthTokens.liquidAccentTintOpacity,
        DepthTokens.liquidAccentAdaptiveMax,
        DepthTokens.liquidAdaptiveLumaLow,
        DepthTokens.liquidAdaptiveLumaHigh,
        DepthTokens.liquidInnerGlow,
        DepthTokens.liquidPressGlow,
        DepthTokens.liquidPressGlowRadius,
        DepthTokens.liquidScrollEdgeTopOpacity,
        DepthTokens.liquidScrollEdgeBottomOpacity,
      ]) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
      expect(DepthTokens.liquidAdaptiveLumaLow,
          lessThan(DepthTokens.liquidAdaptiveLumaHigh));
      expect(DepthTokens.liquidChromeAdaptiveMax,
          greaterThanOrEqualTo(DepthTokens.liquidChromeTintOpacity));
      expect(DepthTokens.liquidModalAdaptiveMax,
          greaterThanOrEqualTo(DepthTokens.liquidModalTintOpacity));
      expect(DepthTokens.liquidControlAdaptiveMax,
          greaterThanOrEqualTo(DepthTokens.liquidControlTintOpacity));
      expect(DepthTokens.liquidAccentAdaptiveMax,
          greaterThanOrEqualTo(DepthTokens.liquidAccentTintOpacity));
      expect(DepthTokens.liquidRimHairline, inInclusiveRange(0.0, 1.0));
      expect(DepthTokens.liquidBottomLight, inInclusiveRange(0.0, 1.0));
      expect(DepthTokens.liquidScrollEdgeBottomOpacity,
          lessThan(DepthTokens.liquidScrollEdgeTopOpacity));
    });
  });

  group('theme wiring (R3)', () {
    test('stays dark, with one accent mapped across every accent slot', () {
      final scheme = AppTheme.darkTheme.colorScheme;
      expect(scheme.brightness, Brightness.dark);
      // The palette collapsed from three accents to one. Material 3 still
      // requires secondary and tertiary slots, so they carry the same hue
      // rather than reintroducing the violet and cyan this removed.
      expect(scheme.primary, Palettes.projectionBooth.primary);
      expect(scheme.secondary, Palettes.projectionBooth.primary);
      expect(scheme.tertiary, Palettes.projectionBooth.primary);
    });

    test('surface hierarchy is driven by the palette', () {
      final scheme = AppTheme.darkTheme.colorScheme;
      expect(scheme.surface, Palettes.projectionBooth.background);
      expect(scheme.surfaceContainer, Palettes.projectionBooth.surface);
      expect(scheme.surfaceContainerHighest,
          Palettes.projectionBooth.surfaceVariant);
      expect(scheme.surfaceBright, Palettes.projectionBooth.surfaceBright);
    });
  });

  group('poster geometry', () {
    test('radiusPoster is a single positive radius for all poster surfaces',
        () {
      expect(DepthTokens.radiusPoster, 8.0);
      expect(DepthTokens.radiusPoster, greaterThan(0));
    });
  });
}
