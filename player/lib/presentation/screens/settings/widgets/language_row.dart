import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/settings/locale_setting.dart';
import '../../../../l10n/l10n.dart';
import '../../../../l10n/locale_names.dart';
import '../../../widgets/language_picker.dart';
import 'settings_row.dart';

/// The Appearance section's language row. The choice lives on this device,
/// so the row works while server settings are loading or failed.
class LanguageSettingsRow extends ConsumerWidget {
  const LanguageSettingsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeSettingProvider);
    final l10n = context.l10n;
    return SettingsRow.navigation(
      key: const Key('language-row'),
      icon: Icons.translate,
      title: l10n.settingsLanguageTitle,
      subtitle: l10n.settingsLanguageSubtitle,
      value: locale == null
          ? l10n.settingsLanguageSystemDefault
          : localeDisplayName(locale),
      onTap: () async {
        final notifier = ref.read(localeSettingProvider.notifier);
        final choice = await showLanguagePicker(context, locale);
        switch (choice) {
          case LanguageSystemDefault():
            await notifier.set(null);
          case LanguagePicked(:final locale):
            await notifier.set(locale);
          case null:
            break;
        }
      },
    );
  }
}
