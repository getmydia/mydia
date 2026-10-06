import 'package:flutter/material.dart';

import '../../../core/config/web_config.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/navigation/source_nav.dart';
import '../focus_highlight.dart';
import '../glass_surface.dart';
import '../toast/toast_obstruction.dart';
import 'dock_glass.dart';
import 'nav_badges.dart';

/// The bar's items out of a source's [entries]: Home, Movies, Shows, then
/// Downloads (Favorites where downloads are unsupported) and Settings. An
/// entry the source cannot serve is left out.
List<SourceNavEntry> bottomNavEntries(
  List<SourceNavEntry> entries, {
  required bool downloadSupported,
}) {
  final ids = [
    'home',
    'movies',
    'shows',
    if (downloadSupported) 'downloads' else 'favorites',
    'settings',
  ];
  return [
    for (final id in ids) ...entries.where((e) => e.id == id).take(1),
  ];
}

/// Mobile bottom navigation bar
class BottomNav extends StatelessWidget {
  final String location;
  final ValueChanged<String> onNavigate;

  /// The bar's items, in order. The shell picks them from the current
  /// source's navigation (see [bottomNavEntries]).
  final List<SourceNavEntry> entries;
  final bool isOffline;
  final bool showBackToMydia;

  const BottomNav({
    super.key,
    required this.location,
    required this.onNavigate,
    required this.entries,
    this.isOffline = false,
    this.showBackToMydia = false,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(DockGlass.sideMargin, 0,
            DockGlass.sideMargin, DockGlass.sideMargin),
        child: ToastObstruction(
          edge: ToastEdge.bottom,
          child: DecoratedBox(
            // Drop shadow lives on an outer box; GlassSurface clips its own
            // blurred fill so the pill now reads as true frosted glass over the
            // ambient backdrop instead of a near-opaque surface.
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              boxShadow: DockGlass.shadow,
            ),
            child: GlassSurface(
              blurSigma: DockGlass.blurSigma,
              fillColor: DockGlass.fill,
              borderRadius: BorderRadius.circular(22),
              border: DockGlass.border,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    if (showBackToMydia)
                      const NavItem(
                        icon: Icons.arrow_back_rounded,
                        selectedIcon: Icons.arrow_back_rounded,
                        label: 'Mydia',
                        isSelected: false,
                        onTap: navigateToMydiaApp,
                      ),
                    for (final entry in entries)
                      if (entry.id == 'settings')
                        SettingsNavItem(
                          location: location,
                          isSelected: entry.matches(location),
                          isDisabled: isOffline,
                          onTap: () => onNavigate(entry.route),
                        )
                      else
                        NavItem(
                          icon: entry.icon,
                          selectedIcon: entry.selectedIcon,
                          label: entry.shortLabel ?? entry.label,
                          isSelected: entry.matches(location),
                          isDisabled: isOffline && entry.id != 'downloads',
                          onTap: () => onNavigate(entry.route),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NavItem extends StatefulWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool isSelected;
  final bool isDisabled;
  final VoidCallback onTap;
  final Widget? badge;

  const NavItem({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.isDisabled = false,
    this.badge,
  });

  @override
  State<NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<NavItem> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails details) {
    _controller.forward();
  }

  void _handleTapUp(TapUpDetails details) {
    _controller.reverse();
    widget.onTap();
  }

  void _handleTapCancel() {
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveColor = widget.isDisabled
        ? AppColors.textDisabled
        : widget.isSelected
            ? AppColors.primary
            : AppColors.textSecondary;

    return FocusHighlight(
      onActivate: widget.onTap,
      // Matches the pill `BoxDecoration.borderRadius` below: the ring traces
      // that exact rectangle, so the two radii must move together.
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      child: GestureDetector(
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: widget.isSelected && !widget.isDisabled
                  ? AppColors.primary.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        widget.isSelected && !widget.isDisabled
                            ? widget.selectedIcon
                            : widget.icon,
                        key: ValueKey(
                            '${widget.isSelected}_${widget.isDisabled}'),
                        color: effectiveColor,
                        size: 24,
                      ),
                    ),
                    if (widget.badge != null)
                      Positioned(
                        top: -3,
                        right: -3,
                        child: widget.badge!,
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: widget.isSelected && !widget.isDisabled
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: effectiveColor,
                  ),
                  child: Text(widget.label),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
