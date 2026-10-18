import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/contrast.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_adaptive.dart';

void main() {
  group('liquidAdaptiveAlpha', () {
    test('dark backdrop keeps the base alpha', () {
      expect(liquidAdaptiveAlpha(base: 0.3, max: 0.65, backdropLuma: 0.0), 0.3);
    });
    test('bright backdrop reaches the max', () {
      expect(liquidAdaptiveAlpha(base: 0.3, max: 0.65, backdropLuma: 1.0),
          closeTo(0.65, 1e-9));
    });
    test('midpoint follows smoothstep', () {
      final mid = (DepthTokens.liquidAdaptiveLumaLow +
              DepthTokens.liquidAdaptiveLumaHigh) /
          2;
      expect(liquidAdaptiveAlpha(base: 0.2, max: 0.6, backdropLuma: mid),
          closeTo(0.4, 1e-9));
    });
    test('a max below the base never lowers it', () {
      expect(
          liquidAdaptiveAlpha(base: 0.85, max: 0.5, backdropLuma: 1.0), 0.85);
    });
  });

  group('accentGlassTint', () {
    const accents = <Color>[
      Color(0xFF0A84FF),
      Color(0xFFFFD60A),
      Color(0xFF30D158),
      Color(0xFFFF375F),
      Color(0xFFBF5AF2),
      Color(0xFFFF9F0A),
      Color(0xFF8E8E93),
      Color(0xFFFFFFFF),
    ];
    for (final accent in accents) {
      test('white clears 4.5:1 over $accent at the max on white', () {
        final tint = accentGlassTint(accent);
        final bg = Color.alphaBlend(
            tint.withValues(alpha: DepthTokens.liquidAccentAdaptiveMax),
            Colors.white);
        expect(contrastRatio(Colors.white, bg), greaterThanOrEqualTo(4.5));
        expect(tint.a, 1.0);
      });
    }
    test('an already dark accent is unchanged', () {
      const deep = Color(0xFF003A80);
      expect(accentGlassTint(deep), deep);
    });
  });
}
