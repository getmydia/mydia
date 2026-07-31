// U1 — depth/material token module (plan R1, R2, R3).
//
// Verifies the token groups expose the documented constants with the expected
// types, that the surface-tone hierarchy is monotonic (real layered depth, not
// near-identical greys), and that wiring the tones into the theme keeps it
// dark-only with the cinematic palette unchanged (R3).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/core/theme/depth_tokens.dart';

/// WCAG relative luminance of an opaque [color] (channels already 0..1).
double _luminance(Color color) {
  return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
}

void main() {
  group('surface tones (R1)', () {
    test('exposes the layered tone hierarchy as Colors', () {
      expect(DepthTokens.surfaceTones, everyElement(isA<Color>()));
      expect(DepthTokens.surfaceTones.length, 7);
      // First and last are the base and brightest surface.
      expect(DepthTokens.surfaceTones.first, DepthTokens.surfaceBase);
      expect(DepthTokens.surfaceTones.last, DepthTokens.surfaceBright);
    });

    test('steps increase monotonically in luminance (distinguishable layers)',
        () {
      final tones = DepthTokens.surfaceTones;
      for (var i = 1; i < tones.length; i++) {
        expect(
          _luminance(tones[i]),
          greaterThan(_luminance(tones[i - 1])),
          reason: 'tone $i should be lighter than tone ${i - 1}',
        );
      }
    });

    test('base tone is the cinematic background, not a new hue (R3)', () {
      expect(DepthTokens.surfaceBase, AppColors.background);
      expect(DepthTokens.surfaceContainer, AppColors.surface);
      expect(DepthTokens.surfaceVariant, AppColors.surfaceVariant);
    });
  });

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

  group('player chrome glass', () {
    test('is more transparent and more blurred than browse chrome', () {
      // The player panel sits over live video, so it can afford real
      // transparency; browse chrome sits over static art and cannot.
      expect(
        DepthTokens.playerChromeFillOpacity,
        lessThan(DepthTokens.chromeFillOpacity),
      );
      expect(
        DepthTokens.blurPlayerChrome,
        greaterThan(DepthTokens.blurChrome),
      );
    });

    test('boosts backdrop saturation', () {
      expect(DepthTokens.playerChromeSaturation, greaterThan(1.0));
    });

    test('fill gradient brackets the nominal opacity', () {
      expect(
        DepthTokens.playerChromeFillTopAlpha,
        greaterThan(DepthTokens.playerChromeFillOpacity),
      );
      expect(
        DepthTokens.playerChromeFillBottomAlpha,
        lessThan(DepthTokens.playerChromeFillOpacity),
      );
      // Denser at the top, where the control row sits; sheer at the bottom,
      // where only the scrubber track does.
      expect(
        DepthTokens.playerChromeFillTopAlpha,
        greaterThan(DepthTokens.playerChromeFillBottomAlpha),
      );
    });

    test(
      'the dense end stays under the browse legibility floor — the '
      'redesign\'s actual differentiation claim, guarded directly rather '
      'than via playerChromeFillOpacity (which no production code reads)',
      () {
        expect(
          DepthTokens.playerChromeFillTopAlpha,
          lessThan(DepthTokens.glassLegibilityFloor),
        );
      },
    );

    test('rim is directional: light on top, dark on the bottom', () {
      expect(DepthTokens.playerRimTop.a, greaterThan(0));
      expect(DepthTokens.playerRimBottom.a, greaterThan(0));
      // Top rim is a white highlight, bottom rim is a black shade.
      expect(DepthTokens.playerRimTop.r, greaterThan(0.5));
      expect(DepthTokens.playerRimBottom.r, lessThan(0.5));
    });

    test('tint is neutral — no colour cast to drain backdrop colour', () {
      // Previously this compared the tint against a navy AppColors.background.
      // The ground is neutral now, so the invariant is stated absolutely: the
      // tint must carry no perceptible cast in any direction, otherwise the
      // blurred, saturated backdrop behind the playback panel gets drained
      // toward that hue instead of showing the video's own colour.
      final t = DepthTokens.playerChromeTint;
      const tolerance = 2 / 255;
      expect((t.b - t.r).abs(), lessThanOrEqualTo(tolerance));
      expect((t.g - t.r).abs(), lessThanOrEqualTo(tolerance));
    });

    test('exposes panel and pill radii', () {
      expect(DepthTokens.radiusPlayerPanel, 16.0);
      expect(DepthTokens.radiusPlayerPill, 18.0);
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

  group('theme wiring (R3)', () {
    test('stays dark with the cinematic primary/secondary/accent hues', () {
      final scheme = AppTheme.darkTheme.colorScheme;
      expect(scheme.brightness, Brightness.dark);
      expect(scheme.primary, AppColors.primary);
      expect(scheme.secondary, AppColors.secondary);
      expect(scheme.tertiary, AppColors.accent);
    });

    test('surface hierarchy is driven by the depth tokens', () {
      final scheme = AppTheme.darkTheme.colorScheme;
      expect(scheme.surface, DepthTokens.surfaceBase);
      expect(scheme.surfaceContainer, DepthTokens.surfaceContainer);
      expect(scheme.surfaceContainerHighest, DepthTokens.surfaceVariant);
      expect(scheme.surfaceBright, DepthTokens.surfaceBright);
    });
  });
}
