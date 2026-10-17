import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/theme_preset.dart';

void main() {
  for (final preset in ThemePreset.values) {
    test('${preset.name} theme is built from its palette', () {
      final p = preset.palette();
      final theme = AppTheme.build(p);
      expect(theme.extension<MydiaPalette>(), p);
      expect(theme.colorScheme.surface, p.background);
      expect(theme.colorScheme.surfaceContainer, p.surface);
      expect(theme.colorScheme.surfaceContainerHighest, p.surfaceVariant);
      expect(theme.colorScheme.surfaceBright, p.surfaceBright);
      expect(theme.colorScheme.primary, p.primary);
      expect(theme.colorScheme.onPrimary, p.onPrimary);
      expect(theme.colorScheme.onSurface, p.textPrimary);
      expect(theme.appBarTheme.backgroundColor, p.background);
      expect(theme.dialogTheme.backgroundColor, p.surface);
      expect(theme.elevatedButtonTheme.style?.foregroundColor?.resolve({}),
          p.background);
    });
  }

  test('darkTheme is Projection Booth', () {
    expect(
        AppTheme.darkTheme.extension<MydiaPalette>(), Palettes.projectionBooth);
  });
}
