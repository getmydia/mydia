// The OSD material's legibility contract, computed from the tokens.
//
// Worst case is the fill alone over a pure-white frame (see
// test/test_utils/osd_contrast.dart for why blur drops out and the shadow is
// not credited). Text holds WCAG SC 1.4.3 (4.5:1), icons SC 1.4.11 (3:1).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/video_controls/center_play_button.dart';

import '../../../test_utils/osd_contrast.dart';

void main() {
  group('OSD material over a pure-white frame', () {
    test('composites to ~#303030', () {
      final bg = osdWorstCaseBackground;
      expect((bg.r * 255).round(), 48);
      expect(relativeLuminance(bg), closeTo(0.029, 0.001));
    });

    for (final color in osdTextColors) {
      test('text colour $color clears 4.5:1', () {
        expect(osdContrast(color), greaterThanOrEqualTo(4.5));
      });
    }

    for (final color in osdIconOnlyColors) {
      test('icon colour $color clears 3:1', () {
        expect(osdContrast(color), greaterThanOrEqualTo(3.0));
      });
    }

    test('textDisabled and warning miss 4.5:1, so neither is OSD text', () {
      expect(osdContrast(AppColors.textDisabled), lessThan(4.5));
      expect(osdContrast(AppColors.warning), lessThan(4.5));
      expect(osdTextColors, isNot(contains(AppColors.textDisabled)));
      expect(osdTextColors, isNot(contains(AppColors.warning)));
    });

    test('at the stats panel\'s old 0.80 fill, textSecondary would fail', () {
      final bg = compositeOver(
        DepthTokens.osdTint.withValues(alpha: 0.80),
        Colors.white,
      );
      expect(contrastRatio(AppColors.textSecondary, bg), lessThan(4.5));
    });
  });

  // CenterPlayButton paints straight onto video with no surface behind it,
  // so its shadow alone has to carry the 3:1 non-text floor.
  test('CenterPlayButton glyph clears 3:1 on a white frame via its shadow', () {
    const shadow = CenterPlayButton.glyphShadow;
    final shaded = compositeOver(shadow.color, Colors.white);
    expect(contrastRatio(Colors.white, shaded), greaterThanOrEqualTo(3.0));
  });
}
