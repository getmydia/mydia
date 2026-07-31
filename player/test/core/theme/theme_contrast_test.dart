// Guards the palette's WCAG 2.1 contrast floors.
//
// Added with the Projection Booth repalette, which found two pre-existing
// failures that nothing in the suite caught:
//   - onPrimary (#FFFFFF) on primary (#4B8DF7) measured 3.25:1. Filled button
//     labels ship at 14px semibold, which is not "large text" under SC 1.4.3
//     (that needs 18.66px bold or 24px), so the 4.5:1 floor applies.
//   - textDisabled (#546580) measured 3.19:1 on background, while its own
//     comment in colors.dart claimed "~4.5:1 contrast".
//
// Everything here is computed from the tokens rather than hardcoded, so the
// floors keep holding as the palette moves.

import 'dart:math' as math;

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';

/// WCAG 2.1 relative luminance. Flutter's `Color.r/g/b` are already 0..1
/// gamma-encoded sRGB, so they are linearised here before weighting.
double _luminance(Color color) {
  double channel(double s) =>
      s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// WCAG 2.1 contrast ratio, order-independent.
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// SC 1.4.3 Contrast (Minimum), normal-size text.
const double _textFloor = 4.5;

void main() {
  group('WCAG text contrast floors', () {
    const onBackground = <String, Color>{
      'primary': AppColors.primary,
      'textPrimary': AppColors.textPrimary,
      'textSecondary': AppColors.textSecondary,
      'textDisabled': AppColors.textDisabled,
      'error': AppColors.error,
      'warning': AppColors.warning,
      'success': AppColors.success,
      'info': AppColors.info,
    };

    onBackground.forEach((name, color) {
      test('$name clears $_textFloor:1 on the app background', () {
        final ratio = _contrast(color, AppColors.background);
        expect(
          ratio,
          greaterThanOrEqualTo(_textFloor),
          reason: 'AppColors.$name measured '
              '${ratio.toStringAsFixed(2)}:1 against AppColors.background. '
              'Adjust the token, never this floor.',
        );
      });
    });

    test('filled primary buttons clear $_textFloor:1 for their own label', () {
      final ratio = _contrast(AppColors.onPrimary, AppColors.primary);
      expect(
        ratio,
        greaterThanOrEqualTo(_textFloor),
        reason: 'AppColors.onPrimary on AppColors.primary measured '
            '${ratio.toStringAsFixed(2)}:1. This is the defect the Projection '
            'Booth palette fixed; it must not come back.',
      );
    });
  });
}
