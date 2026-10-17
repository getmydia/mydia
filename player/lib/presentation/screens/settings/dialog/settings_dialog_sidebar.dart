import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import 'settings_dialog.dart';

class SettingsDialogSidebar extends StatelessWidget {
  const SettingsDialogSidebar({
    super.key,
    required this.selected,
    required this.compact,
    required this.onSelect,
  });

  final SettingsCategory selected;
  final bool compact;
  final ValueChanged<SettingsCategory> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: compact ? 64 : 200,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 16),
        children: [
          for (final c in SettingsCategory.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: ListTile(
                key: Key('settings-category-${c.name}'),
                selected: c == selected,
                selectedTileColor: scheme.primary.withValues(alpha: 0.14),
                selectedColor: AppColors.textPrimary,
                iconColor: AppColors.textSecondary,
                dense: true,
                // Icon-only: centre the 20px icon in the 48px tile. The icon
                // must stay narrower than the tile minus padding, or ListTile
                // asserts that it consumes the whole width.
                contentPadding:
                    compact ? const EdgeInsets.symmetric(horizontal: 13) : null,
                minLeadingWidth: compact ? 0 : null,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                leading: SizedBox(
                  width: 20,
                  child: compact
                      ? Tooltip(
                          message: c.label,
                          child: Icon(c.icon, size: 20),
                        )
                      : Icon(c.icon, size: 20),
                ),
                title: compact
                    ? null
                    : Text(c.label,
                        key: Key('settings-category-label-${c.name}')),
                onTap: () => onSelect(c),
              ),
            ),
        ],
      ),
    );
  }
}
