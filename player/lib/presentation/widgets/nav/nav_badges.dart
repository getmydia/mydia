import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/player/platform_features.dart';
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

  /// The shell location the badge sits in, for the source it describes.
  final String location;

  const SettingsBadge({
    super.key,
    required this.location,
    this.supportedOverride,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Not a synchronous UpdateHost.current() guess, which cannot tell a
    // sideloaded Android install from a Play one and used to hide this badge
    // on the one platform that most needs it. createUpdateBackend never
    // builds a backend anywhere self-update is unsupported, so an
    // availableUpdate below already proves the platform qualifies.
    final supported = supportedOverride ?? true;
    final updatePending = supported &&
        !PlatformFeatures.isMacOS &&
        ref.watch(updateProvider).availableUpdate != null;

    return ConnectionStatusDot(
      location: location,
      updatePending: updatePending,
    );
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

  /// Forwarded to the wrapped [SidebarRow]. See its docs.
  final FocusNode? focusNode;

  /// The shell location, for the badge's source.
  final String location;

  const SettingsSidebarRow({
    super.key,
    required this.location,
    required this.isSelected,
    required this.isDisabled,
    required this.onTap,
    this.isEditing = false,
    this.isHidden = false,
    this.editingTrailing,
    this.focusNode,
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
      badge: SettingsBadge(location: location),
      isEditing: isEditing,
      isHidden: isHidden,
      editingTrailing: editingTrailing,
      focusNode: focusNode,
    );
  }
}

/// Settings nav item with connection status badge.
class SettingsNavItem extends ConsumerWidget {
  final bool isSelected;
  final bool isDisabled;
  final VoidCallback onTap;

  /// The shell location, for the badge's source.
  final String location;

  const SettingsNavItem({
    super.key,
    required this.location,
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
      badge: SettingsBadge(location: location),
    );
  }
}
