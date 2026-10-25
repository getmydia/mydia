import 'package:flutter/material.dart';

import '../../core/theme/palette.dart';
import '../../l10n/l10n.dart';
import '../../l10n/locale_names.dart';
import 'osd_dialog.dart';

/// What the viewer chose in [showLanguagePicker]. A dismissal is a null
/// result instead, so "System default" stays distinguishable from "never
/// mind".
sealed class LanguageChoice {
  const LanguageChoice();
}

/// Follow the device language.
class LanguageSystemDefault extends LanguageChoice {
  const LanguageSystemDefault();
}

/// Use this language regardless of the device.
class LanguagePicked extends LanguageChoice {
  const LanguagePicked(this.locale);

  final Locale locale;
}

/// Shows System default plus every shipped language and returns the choice,
/// or null if the viewer dismissed the dialog. Same tile shape as the theme
/// picker, so it works with D-pad focus on TV.
Future<LanguageChoice?> showLanguagePicker(
  BuildContext context,
  Locale? current,
) {
  return showDialog<LanguageChoice>(
    context: context,
    builder: (context) {
      final palette = context.palette;

      Widget tile({
        required Key key,
        required String label,
        required bool selected,
        required LanguageChoice choice,
      }) =>
          ListTile(
            key: key,
            autofocus: selected,
            selected: selected,
            title: Text(
              label,
              style: TextStyle(
                color: palette.textPrimary,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            trailing:
                selected ? Icon(Icons.check, color: palette.primary) : null,
            onTap: () => Navigator.of(context).pop(choice),
          );

      return OsdDialog(
        title: Text(context.l10n.settingsLanguageTitle),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        content: Material(
          type: MaterialType.transparency,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                tile(
                  key: const Key('language-option-system'),
                  label: context.l10n.settingsLanguageSystemDefault,
                  selected: current == null,
                  choice: const LanguageSystemDefault(),
                ),
                for (final l in AppLocalizations.supportedLocales)
                  tile(
                    key: Key('language-option-${l.toLanguageTag()}'),
                    label: localeDisplayName(l),
                    selected: current?.toLanguageTag() == l.toLanguageTag(),
                    choice: LanguagePicked(l),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
