import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/core/theme/palette.dart';

void main() {
  tearDown(() => LiquidGlassSupport.debugPlatformOverride = null);

  OutlinedBorder? shapeOf(ButtonStyle? style) =>
      style?.shape?.resolve(<WidgetState>{});

  test('iOS and macOS: content buttons are capsules with no ripple', () {
    LiquidGlassSupport.debugPlatformOverride = true;
    final theme = AppTheme.build(Palettes.projectionBooth);
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

  test('elsewhere the buttons keep their rounded rectangle', () {
    LiquidGlassSupport.debugPlatformOverride = false;
    final theme = AppTheme.build(Palettes.projectionBooth);
    expect(
        shapeOf(theme.filledButtonTheme.style), isA<RoundedRectangleBorder>());
    expect(theme.filledButtonTheme.style?.splashFactory, isNull);
  });
}
