import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/player/platform_features.dart';
import '../../../core/update/update_host.dart';
import '../../../core/update/update_provider.dart';
import '../connection_status_dot.dart';
import 'bottom_nav.dart';
import 'sidebar_row.dart';

/// The badge on the Settings nav item.
///
/// Carries two independent signals on one 14px mark: connection tone as
/// colour, and a waiting update as an arrow glyph. It deliberately ignores
/// the dismissal box, the compatibility verdict and offline mode, so
/// dismissing the banner leaves this lit as the lingering reminder that makes
/// per-version dismissal safe to offer.
class SettingsBadge extends ConsumerWidget {
  /// Overrides the platform-support check. Tests only, as in [UpdateBanner].
  final bool? supportedOverride;

  const SettingsBadge({super.key, this.supportedOverride});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supported =
        supportedOverride ?? UpdateHost.current().supportsInAppUpdates;
    final updatePending = supported &&
        !PlatformFeatures.isMacOS &&
        ref.watch(updateProvider).availableUpdate != null;

    return ConnectionStatusDot(updatePending: updatePending);
  }
}

/// Settings sidebar item with connection status badge.
class SettingsSidebarRow extends ConsumerWidget {
  final bool isSelected;
  final bool isDisabled;
  final VoidCallback onTap;

  /// Forwarded to the wrapped [SidebarRow]. See its docs.
  final bool isEditing;
  final bool isHidden;
  final Widget? editingTrailing;

  const SettingsSidebarRow({
    super.key,
    required this.isSelected,
    required this.isDisabled,
    required this.onTap,
    this.isEditing = false,
    this.isHidden = false,
    this.editingTrailing,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SidebarRow(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      label: 'Settings',
      isSelected: isSelected,
      isDisabled: isDisabled,
      onTap: onTap,
      badge: const SettingsBadge(),
      isEditing: isEditing,
      isHidden: isHidden,
      editingTrailing: editingTrailing,
    );
  }
}

/// Settings nav item with connection status badge.
class SettingsNavItem extends ConsumerWidget {
  final bool isSelected;
  final bool isDisabled;
  final VoidCallback onTap;

  const SettingsNavItem({
    super.key,
    required this.isSelected,
    required this.isDisabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NavItem(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      label: 'Settings',
      isSelected: isSelected,
      isDisabled: isDisabled,
      onTap: onTap,
      badge: const SettingsBadge(),
    );
  }
}
