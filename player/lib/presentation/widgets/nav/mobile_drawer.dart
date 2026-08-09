import 'package:flutter/material.dart';

import '../../../core/config/web_config.dart';
import '../../../core/theme/colors.dart';
import '../app_shell.dart';
import 'sidebar_row.dart';

/// Full-screen drawer for mobile navigation, mirrors the desktop sidebar.
class MobileDrawer extends StatelessWidget {
  final String location;
  final ValueChanged<String> onNavigate;
  final bool homeExpanded;
  final bool libraryExpanded;
  final VoidCallback onToggleHome;
  final VoidCallback onToggleLibrary;
  final bool showBackToMydia;
  final bool isOffline;

  const MobileDrawer({
    super.key,
    required this.location,
    required this.onNavigate,
    required this.homeExpanded,
    required this.libraryExpanded,
    required this.onToggleHome,
    required this.onToggleLibrary,
    this.showBackToMydia = false,
    this.isOffline = false,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: AppColors.background,
      child: SafeArea(
        child: SidebarContent(
          location: location,
          onNavigate: onNavigate,
          homeExpanded: homeExpanded,
          libraryExpanded: libraryExpanded,
          onToggleHome: onToggleHome,
          onToggleLibrary: onToggleLibrary,
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
}
