import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';

void main() {
  OutlinedBorder? shapeOf(ButtonStyle? style) =>
      style?.shape?.resolve(<WidgetState>{});

  test('Liquid Glass: content buttons are capsules with no ripple', () {
    final theme = AppTheme.build(Palettes.projectionBooth, liquid: true);
    for (final style in [
      theme.filledButtonTheme.style,
      theme.elevatedButtonTheme.style,
      theme.textButtonTheme.style,
      theme.outlinedButtonTheme.style,
    ]) {
      expect(shapeOf(style), isA<StadiumBorder>());
      expect(style?.splashFactory, NoSplash.splashFactory);
    }
  });

  test('Frosted: the buttons keep their rounded rectangle', () {
    final theme = AppTheme.build(Palettes.projectionBooth, liquid: false);
    expect(
        shapeOf(theme.filledButtonTheme.style), isA<RoundedRectangleBorder>());
    expect(theme.filledButtonTheme.style?.splashFactory, isNull);
  });
}
