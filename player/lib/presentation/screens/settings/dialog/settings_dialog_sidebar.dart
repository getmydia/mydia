/// The settings dialog's sidebar: who you are, the categories in two groups,
/// and the connection and update status beside the categories they concern.
///
/// Takes plain values rather than reading providers, so it pumps without a
/// `ProviderScope`; `SettingsSidebarStatus` is what wires state into it.
library;

import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/palette.dart';
import '../../../../l10n/l10n.dart';
import '../widgets/settings_avatar.dart';
import 'settings_dialog.dart';

/// The sidebar's width with labels. Compact mode is a 64px icon rail.
const double kSettingsSidebarWidth = 236;
const double kSettingsSidebarCompactWidth = 64;

/// The signed-in Mydia account the card at the top of the sidebar names.
class SettingsSidebarAccount {
  const SettingsSidebarAccount({
    required this.username,
    required this.serverUrl,
  });

  final String username;
  final String serverUrl;
}

/// A category's icon tile colours: a muted [background] at similar lightness
/// across categories, and the [foreground] its icon is drawn in.
typedef SettingsCategoryTint = ({Color background, Color foreground});

extension SettingsCategoryTints on SettingsCategory {
  SettingsCategoryTint tint(MydiaPalette palette) => switch (this) {
    SettingsCategory.connections => (
      background: const Color(0xFF1F3330),
      foreground: const Color(0xFF7CC7B6),
    ),
    SettingsCategory.backup => (
      background: const Color(0xFF1E2C40),
      foreground: const Color(0xFF82AEEA),
    ),
    SettingsCategory.playback => (
      background: Color.alphaBlend(
        palette.primary.withValues(alpha: 0.18),
        palette.surface,
      ),
      foreground: palette.primary,
    ),
    SettingsCategory.appearance => (
      background: const Color(0xFF2B2F3A),
      foreground: const Color(0xFFA9B6D4),
    ),
    SettingsCategory.diagnostics => (
      background: const Color(0xFF2E2638),
      foreground: const Color(0xFFB9A2DA),
    ),
    SettingsCategory.about => (
      background: palette.surfaceBright,
      foreground: palette.textSecondary,
    ),
  };
}

class SettingsDialogSidebar extends StatelessWidget {
  const SettingsDialogSidebar({
    super.key,
    required this.selected,
    required this.compact,
    required this.onSelect,
    this.account,
    this.connectionStatus,
    this.updateAvailable = false,
  });

  final SettingsCategory selected;
  final bool compact;
  final ValueChanged<SettingsCategory> onSelect;

  /// Null hides the account card.
  final SettingsSidebarAccount? account;

  /// Drawn at the end of the Servers & devices item.
  final Widget? connectionStatus;

  /// Shows an "Update" pill at the end of the About item.
  final bool updateAvailable;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final current = account;
    return SizedBox(
      width: compact ? kSettingsSidebarCompactWidth : kSettingsSidebarWidth,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          compact ? 8 : 12,
          16,
          compact ? 8 : 12,
          16,
        ),
        children: [
          if (!compact && current != null) ...[
            _AccountCard(
              account: current,
              onTap: () => onSelect(SettingsCategory.connections),
            ),
            const SizedBox(height: 14),
          ],
          for (final c in SettingsCategory.values) ...[
            if (c.startsGroup)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Divider(height: 1, thickness: 1, color: palette.divider),
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: _CategoryItem(
                category: c,
                selected: c == selected,
                compact: compact,
                onTap: () => onSelect(c),
                trailing: compact
                    ? null
                    : switch (c) {
                        SettingsCategory.connections => connectionStatus,
                        SettingsCategory.about when updateAvailable =>
                          const _UpdatePill(),
                        _ => null,
                      },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CategoryItem extends StatelessWidget {
  const _CategoryItem({
    required this.category,
    required this.selected,
    required this.compact,
    required this.onTap,
    this.trailing,
  });

  final SettingsCategory category;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = context.l10n;
    final label = category.label(l10n);
    final tint = category.tint(palette);
    final radius = BorderRadius.circular(9);

    Widget tile = Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? tint.foreground : tint.background,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(
        category.icon,
        size: 15,
        color: selected ? tint.background : tint.foreground,
      ),
    );
    if (compact) tile = Tooltip(message: label, child: tile);

    final end = trailing;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        key: Key('settings-category-${category.name}'),
        color: selected
            ? palette.primary.withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: SizedBox(
            height: 34,
            child: compact
                ? Center(child: tile)
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Row(
                      children: [
                        tile,
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            label,
                            key: Key(
                              'settings-category-label-${category.name}',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: selected
                                  ? palette.textPrimary
                                  : palette.textSecondary,
                            ),
                          ),
                        ),
                        if (end != null) ...[const SizedBox(width: 8), end],
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account, required this.onTap});

  final SettingsSidebarAccount account;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final username = account.username;
    final host = _hostOf(account.serverUrl);
    final radius = BorderRadius.circular(12);
    return Semantics(
      button: true,
      child: Material(
        key: const Key('settings-sidebar-account'),
        color: palette.surfaceHigh,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                SettingsAvatar(
                  username: username,
                  size: 34,
                  color: palette.surfaceBright,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        username.isEmpty
                            ? context.l10n.settingsIdentitySignedIn
                            : username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: palette.textPrimary,
                        ),
                      ),
                      if (host.isNotEmpty)
                        Text(
                          host,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: palette.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The URL's host, or the whole value when it has none: a stored
  /// `mydia.local:4000` parses with `mydia.local` as its scheme.
  static String _hostOf(String serverUrl) {
    final host = Uri.tryParse(serverUrl)?.host;
    return host == null || host.isEmpty ? serverUrl : host;
  }
}

class _UpdatePill extends StatelessWidget {
  const _UpdatePill();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      key: const Key('settings-sidebar-update-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: palette.primary.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        context.l10n.settingsUpdateBadge,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: palette.primary,
        ),
      ),
    );
  }
}
