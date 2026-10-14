import 'package:flutter/material.dart';

import '../../../core/config/web_config.dart';
import '../../../core/theme/colors.dart';
import '../native_glass.dart';
import 'sidebar_content.dart';
import 'sidebar_row.dart';

/// Full-screen drawer for mobile navigation, mirrors the desktop sidebar.
class MobileDrawer extends StatelessWidget {
  final String location;
  final ValueChanged<String> onNavigate;
  final ValueChanged<String>? onSwitchSource;
  final bool showBackToMydia;
  final bool isOffline;

  const MobileDrawer({
    super.key,
    required this.location,
    required this.onNavigate,
    this.onSwitchSource,
    this.showBackToMydia = false,
    this.isOffline = false,
  });

  @override
  Widget build(BuildContext context) {
    return surface(
      child: SafeArea(
        child: SidebarContent(
          location: location,
          onNavigate: onNavigate,
          onSwitchSource: onSwitchSource,
          isOffline: isOffline,
          backToMydiaWidget: showBackToMydia
              ? SidebarRow(
                  icon: Icons.arrow_back_rounded,
                  selectedIcon: Icons.arrow_back_rounded,
                  label: 'Back to Mydia',
                  isSelected: false,
                  onTap: () {
                    Navigator.of(context).pop();
                    navigateToMydiaApp();
                  },
                )
              : null,
        ),
      ),
    );
  }

  /// The drawer chrome around [child]: Apple's native glass where the OS has
  /// it, otherwise the opaque background the drawer has always had. The
  /// drawer was never frosted, so there is no Flutter glass fallback to keep.
  ///
  /// Square while native, because [NativeGlass] takes one uniform radius and
  /// the drawer's edge has to match the glass under it.
  ///
  /// Public and `@visibleForTesting` so a test can check the chrome without
  /// mounting `SidebarContent`'s provider graph.
  @visibleForTesting
  static Widget surface({required Widget child}) {
    final native = NativeGlass.available;
    return Drawer(
      backgroundColor: native ? Colors.transparent : AppColors.background,
      shape: native ? const RoundedRectangleBorder() : null,
      child: NativeGlass(
        cornerRadius: 0,
        fallback: (child) => child,
        child: child,
      ),
    );
  }
}
