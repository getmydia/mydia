import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Preset-dependent colours live in `MydiaPalette`. A palette field coming
/// back to `AppColors` would silently ignore the viewer's theme.
void main() {
  test('AppColors declares no palette colours', () {
    final source = File('lib/core/theme/colors.dart').readAsStringSync();
    const paletteFields = [
      'background',
      'surface',
      'surfaceVariant',
      'primary',
      'primaryFocus',
      'onPrimary',
      'neutral',
      'neutralFocus',
      'textPrimary',
      'textSecondary',
      'textDisabled',
      'divider',
      'border',
      'cardHover',
      'shimmerBase',
      'shimmerHighlight',
    ];
    for (final field in paletteFields) {
      expect(
        RegExp('static const Color $field\\b').hasMatch(source),
        isFalse,
        reason: 'AppColors.$field belongs in MydiaPalette (palette.dart).',
      );
    }
  });
}
