import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection_status_dot.dart';
import 'bottom_nav.dart';
import 'sidebar_row.dart';

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
      badge: const ConnectionStatusDot(),
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
      badge: const ConnectionStatusDot(),
    );
  }
}
