// The OSD material's legibility contract, computed from the tokens.
//
// Worst case is the fill alone over a pure-white frame (see
// test/test_utils/osd_contrast.dart for why blur drops out and the shadow is
// not credited). Text holds WCAG SC 1.4.3 (4.5:1), icons SC 1.4.11 (3:1).

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/theme_preset.dart';
import 'package:player/presentation/widgets/video_controls/chrome_scrim.dart';
import 'package:player/presentation/widgets/video_controls/chrome_title_block.dart';
import 'package:player/presentation/widgets/video_controls/touch_transport.dart';

import '../../../test_utils/mac_accents.dart';
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

    test('warning misses 4.5:1, so it is not OSD text', () {
      expect(osdContrast(AppColors.warning), lessThan(4.5));
      expect(osdTextColors, isNot(contains(AppColors.warning)));
    });

    for (final preset in ThemePreset.values) {
      final palette = preset.palette();

      test('${preset.name}: textPrimary and textSecondary clear 4.5:1', () {
        expect(osdContrast(palette.textPrimary), greaterThanOrEqualTo(4.5));
        expect(osdContrast(palette.textSecondary), greaterThanOrEqualTo(4.5));
      });

      // The accent is drawn as text and icon colour on the OSD (toast actions,
      // selected-state checks). The macOS accent is the viewer's, so check
      // every accent System Settings offers.
      final primaries = preset == ThemePreset.macos
          ? {
              for (final a in macAccents.entries)
                'macos/${a.key}': preset.palette(systemAccent: a.value).primary,
            }
          : {preset.name: palette.primary};
      primaries.forEach((name, primary) {
        test('$name: primary clears 4.5:1 on the OSD fill', () {
          expect(osdContrast(primary), greaterThanOrEqualTo(4.5));
        });
      });

      test('${preset.name}: textDisabled is not OSD text', () {
        expect(osdContrast(palette.textDisabled), lessThan(4.5));
        expect(osdTextColors, isNot(contains(palette.textDisabled)));
      });

      // The stats panel's old 0.80 fill was too translucent for the default
      // textSecondary. A preset with a lighter textSecondary may clear 4.5:1
      // even there, so the invariant is that the real fill is the more
      // legible one, and that it is the default theme that needed it.
      test('${preset.name}: the OSD fill beats the old 0.80 fill for '
          'textSecondary', () {
        final oldBg = compositeOver(
          DepthTokens.osdTint.withValues(alpha: 0.80),
          Colors.white,
        );
        expect(
          osdContrast(palette.textSecondary),
          greaterThan(contrastRatio(palette.textSecondary, oldBg)),
        );
        if (preset == ThemePreset.projectionBooth) {
          expect(contrastRatio(palette.textSecondary, oldBg), lessThan(4.5));
        }
      });
    }
  });

  // The touch play disc is opaque white-ish, so its dark glyph is text-grade
  // against it even over a pure-white frame.
  test('touch play glyph clears 4.5:1 on its disc', () {
    expect(
      contrastRatio(
        TouchTransport.playGlyph,
        compositeOver(TouchTransport.playFill, Colors.white),
      ),
      greaterThanOrEqualTo(4.5),
    );
  });

  // The title is bare text on the scrim. Its top edge, the kicker's too, is
  // the lightest scrim alpha any title text overlaps, so both lines are rated
  // there over a pure-white frame.
  group('title block on the scrim over a pure-white frame', () {
    const cases = [
      (name: 'pointer', tier: ChromeTitleTier.pointer, height: 1080.0),
      (name: 'compact', tier: ChromeTitleTier.compact, height: 350.0),
      (name: 'remote', tier: ChromeTitleTier.remote, height: 2160.0),
    ];
    for (final c in cases) {
      test('${c.name}: title 3:1, kicker 4.5:1 at the block top', () {
        final titleHeight =
            ChromeTitleBlock.heightFor(c.tier) +
            ChromeTitleBlock.gapFor(c.tier);
        const plateau = 100.0;
        final alpha = ChromeScrim.alphaAt(
          plateau + titleHeight,
          plateau: plateau,
          titleHeight: titleHeight,
          height: c.height,
        );
        final bg = compositeOver(
          DepthTokens.osdTint.withValues(alpha: alpha),
          Colors.white,
        );
        expect(
          contrastRatio(
            compositeOver(Colors.white.withValues(alpha: 0.95), bg),
            bg,
          ),
          greaterThanOrEqualTo(3.0),
        );
        expect(
          contrastRatio(
            compositeOver(
              Colors.white.withValues(alpha: ChromeTitleBlock.kickerOpacity),
              bg,
            ),
            bg,
          ),
          greaterThanOrEqualTo(4.5),
        );
      });
    }
  });
}
