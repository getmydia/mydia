import 'package:flutter/material.dart';

import '../../../core/config/web_config.dart';
import '../../../core/theme/colors.dart';
import 'sidebar_content.dart';
import 'sidebar_row.dart';

/// Full-screen drawer for mobile navigation, mirrors the desktop sidebar.
class MobileDrawer extends StatelessWidget {
  final String location;
  final ValueChanged<String> onNavigate;
  final bool showBackToMydia;
  final bool isOffline;

  const MobileDrawer({
    super.key,
    required this.location,
    required this.onNavigate,
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
