import 'package:flutter/material.dart';

import '../../../core/config/web_config.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/depth_tokens.dart';
import '../../../core/theme/liquid_glass/liquid_glass_support.dart';
import '../glass_surface.dart';
import 'sidebar_content.dart';
import 'sidebar_row.dart';

/// Navigation drawer for the phone layout, mirrors the desktop sidebar.
///
/// On Liquid Glass it floats like the tablet rail: inset from the leading,
/// top and bottom edges, every corner rounded, with the rail's rim and
/// shadow (the shell gives it the rail's scrim). Elsewhere it is a Material
/// drawer flush to the edge.
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
    final content = SidebarContent(
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
    );
    return LiquidGlassSupport.available
        ? _floating(context, content)
        : _edgeToEdge(content);
  }

  /// The Material drawer: flush to the leading edge, right corners rounded.
  Widget _edgeToEdge(Widget content) {
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
        child: SafeArea(child: content),
      ),
    );
  }

  /// The Liquid Glass drawer: the rail's geometry, padded off the safe area.
  /// The Drawer is only a transparent host; it must not clip, or the panel's
  /// shadow would be cut at its trailing edge.
  Widget _floating(BuildContext context, Widget content) {
    const inset = Breakpoints.railInset;
    final safe = MediaQuery.paddingOf(context);
    return Drawer(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      clipBehavior: Clip.none,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          inset + safe.left,
          inset + safe.top,
          0,
          inset + safe.bottom,
        ),
        child: GlassSurface.chrome(
          borderRadius:
              const BorderRadius.all(Radius.circular(AppTheme.radiusRail)),
          border: Border.all(
            color: DepthTokens.rimColor,
            width: DepthTokens.rimWidth,
          ),
          shadows: DepthTokens.chrome,
          // The padding already clears the safe area; drop it so nothing
          // inside insets itself a second time.
          child: MediaQuery.removePadding(
            context: context,
            removeLeft: true,
            removeTop: true,
            removeRight: true,
            removeBottom: true,
            child: content,
          ),
        ),
      ),
    );
  }
}
