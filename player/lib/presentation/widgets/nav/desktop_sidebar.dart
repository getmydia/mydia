import 'package:flutter/material.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/depth_tokens.dart';
import '../glass_surface.dart';
import 'back_to_mydia_button.dart';
import 'sidebar_content.dart';

/// Desktop sidebar navigation with collapsible sections
class DesktopSidebar extends StatelessWidget {
  final String location;
  final ValueChanged<String> onNavigate;
  final bool showBackToMydia;
  final bool isOffline;

  const DesktopSidebar({
    super.key,
    required this.location,
    required this.onNavigate,
    this.showBackToMydia = false,
    this.isOffline = false,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSidebarPanel(
      child: SafeArea(
        top: true,
        child: SidebarContent(
          location: location,
          onNavigate: onNavigate,
          isOffline: isOffline,
          backToMydiaWidget: showBackToMydia ? const BackToMydiaButton() : null,
        ),
      ),
    );
  }
}

/// The desktop sidebar's glass chrome panel (R4/R6/R10).
///
/// A fixed-width, real-blur [GlassSurface] that sits over the shell ambient
/// backdrop and is therefore tinted by the artwork behind it (R5, verified in
/// U8). The light rim defines the right edge and the chrome shadow gives it
/// layered depth — replacing the prior flat `Container(color: background)` +
/// faint 1px border (R6). The chrome fill clears the R10 legibility floor so
/// nav labels stay readable over any backdrop.
///
/// Extracted as a public widget so the glass composition is unit-testable
/// without mounting the full shell's provider graph.
class GlassSidebarPanel extends StatelessWidget {
  final Widget child;

  const GlassSidebarPanel({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: Breakpoints.sidebarWidth,
      child: DecoratedBox(
        decoration: const BoxDecoration(boxShadow: DepthTokens.chrome),
        child: GlassSurface(
          blurSigma: DepthTokens.blurChrome,
          fillColor: AppColors.surface.withValues(
            alpha: DepthTokens.chromeFillOpacity,
          ),
          border: const Border(
            right: BorderSide(
              color: DepthTokens.rimColor,
              width: DepthTokens.rimWidth,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
