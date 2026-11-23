import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/linux_desktop.dart';
import '../../../../core/theme/theme_preset.dart';
import '../../../../core/theme/theme_providers.dart';
import '../../../../l10n/l10n.dart';
import 'settings_choice_grid.dart';
import 'theme_preset_preview.dart';

/// The Appearance section's theme picker: a grid of previews. The preset
/// lives on this device, so it works while server settings are loading or
/// failed.
class ThemePresetSettingsRow extends ConsumerWidget {
  const ThemePresetSettingsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preset = ref.watch(themePresetSettingProvider);
    final linuxDesktop = ref.watch(linuxDesktopProvider);
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: SettingsChoiceGrid<ThemePreset>(
        key: const Key('theme-preset-row'),
        label: l10n.settingsThemeTitle,
        selected: preset,
        choices: [
          for (final option in ThemePreset.availableOn(defaultTargetPlatform))
            SettingsChoice<ThemePreset>(
              value: option,
              label: l10n.themePresetName(option, linuxDesktop: linuxDesktop),
              preview: _Preview(preset: option),
            ),
        ],
        onSelected: (picked) =>
            ref.read(themePresetSettingProvider.notifier).set(picked),
      ),
    );
  }
}

/// Resolves the preset's palette the way the app theme does.
class _Preview extends ConsumerWidget {
  const _Preview({required this.preset});

  final ThemePreset preset;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ThemePresetPreview(palette: ref.watch(presetPaletteProvider(preset)));
}
