// Guards the palette's WCAG 2.1 contrast floors.
//
// Added with the Projection Booth repalette, which found two pre-existing
// failures that nothing in the suite caught:
//   - onPrimary (#FFFFFF) on primary (#4B8DF7) measured 3.25:1. Filled button
//     labels ship at 14px semibold, which is not "large text" under SC 1.4.3
//     (that needs 18.66px bold or 24px), so the 4.5:1 floor applies.
//   - textDisabled (#546580) measured 3.19:1 against the original #0A1120
//     ground and 3.33:1 against the neutral #0B0B0C ground that replaced it,
//     while its own comment in colors.dart claimed "~4.5:1 contrast".
//
// Everything here is computed from the tokens rather than hardcoded, so the
// floors keep holding as the palette moves.

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/core/theme/contrast.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/theme_preset.dart';

import '../../test_utils/mac_accents.dart';

/// SC 1.4.3 Contrast (Minimum), normal-size text.
const double _textFloor = 4.5;

Map<String, MydiaPalette> _palettes() => {
      for (final preset in ThemePreset.values)
        if (preset != ThemePreset.macos) preset.name: preset.palette(),
      for (final accent in macAccents.entries)
        'macos/${accent.key}':
            ThemePreset.macos.palette(systemAccent: accent.value),
    };

void _floor(Color fg, Color bg, String what) {
  final ratio = contrastRatio(fg, bg);
  expect(
    ratio,
    greaterThanOrEqualTo(_textFloor),
    reason: '$what measured ${ratio.toStringAsFixed(2)}:1. '
        'Adjust the token, never this floor.',
  );
}

void main() {
  _palettes().forEach((name, p) {
    group('$name: WCAG text contrast floors', () {
      final onBackground = <String, Color>{
        'primary': p.primary,
        'textPrimary': p.textPrimary,
        'textSecondary': p.textSecondary,
        'textDisabled': p.textDisabled,
        'error': AppColors.error,
        'warning': AppColors.warning,
        'success': AppColors.success,
        'info': AppColors.info,
      };
      onBackground.forEach((token, color) {
        test('$token clears $_textFloor:1 on the background', () {
          _floor(color, p.background, '$token on background');
        });
      });

      test('filled primary buttons clear $_textFloor:1 for their label', () {
        _floor(p.onPrimary, p.primary, 'onPrimary on primary');
      });

      test('white primary buttons clear $_textFloor:1 for their label', () {
        _floor(p.background, const Color(0xFFFFFFFF), 'background on white');
      });

      test('secondary button label clears $_textFloor:1 on its fill', () {
        final fill =
            Color.alphaBlend(AppTheme.secondaryButtonFill, p.background);
        _floor(p.textPrimary, fill, 'textPrimary on secondary fill');
      });

      test('input placeholder text clears $_textFloor:1 on the field fill', () {
        _floor(p.textSecondary, p.surfaceVariant,
            'hintStyle (textSecondary) on surfaceVariant');
      });

      // Known gap this suite deliberately does not close: AppColors.onError
      // (#FFFFFF) on AppColors.error (#F04D4D) measures 3.58:1, under the
      // 4.5:1 floor, and is live via the Material 3 ColorScheme (every error
      // button and snackbar). It predates the Projection Booth repalette, and
      // fixing it changes how those surfaces look everywhere, so it is left as
      // a palette decision for the maintainer rather than asserted here.
    });
  });
}
