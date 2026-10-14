import 'package:flutter/material.dart';

import '../../../core/config/web_config.dart';
import '../../../core/theme/app_theme.dart';
import '../glass_surface.dart';
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
    // The Drawer paints no fill of its own; the glass supplies it and its
    // right-hand corners follow the rail's radius.
    const radius = BorderRadius.horizontal(
      right: Radius.circular(AppTheme.radiusRail),
    );
    return Drawer(
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: radius),
      child: GlassSurface.chrome(
        borderRadius: radius,
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
      ),
    );
  }
}
