import 'package:flutter_test/flutter_test.dart';
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
}
