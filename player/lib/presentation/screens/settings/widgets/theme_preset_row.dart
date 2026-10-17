import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/theme_preset.dart';
import '../../../../core/theme/theme_providers.dart';
import '../../../widgets/theme_preset_picker.dart';
import 'settings_row.dart';

/// The Appearance section's theme row. The preset lives on this device, so
/// the row works while server settings are loading or failed.
class ThemePresetSettingsRow extends ConsumerWidget {
  const ThemePresetSettingsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preset = ref.watch(themePresetSettingProvider);
    return SettingsRow.navigation(
      key: const Key('theme-preset-row'),
      icon: Icons.palette_outlined,
      title: 'Theme',
      subtitle: 'Colours on this device',
      value: preset.label,
      onTap: () async {
        final picked = await showThemePresetPicker(
          context,
          preset,
          ThemePreset.availableOn(defaultTargetPlatform),
        );
        if (picked != null) {
          await ref.read(themePresetSettingProvider.notifier).set(picked);
        }
      },
    );
  }
}
