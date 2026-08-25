import 'package:flutter/material.dart';

import '../../../core/config/web_config.dart';
import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../core/theme/colors.dart';
import '../../../domain/navigation/nav_destination.dart';
import '../focus_highlight.dart';
import '../glass_surface.dart';
import 'nav_badges.dart';

/// Mobile bottom navigation bar
class BottomNav extends StatelessWidget {
  final String location;
  final ValueChanged<String> onNavigate;
  final bool isOffline;
  final bool showBackToMydia;

  const BottomNav({
    super.key,
    required this.location,
    required this.onNavigate,
    this.isOffline = false,
    this.showBackToMydia = false,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: DecoratedBox(
          // Drop shadow lives on an outer box; GlassSurface clips its own
          // blurred fill so the pill now reads as true frosted glass over the
          // ambient backdrop instead of a near-opaque surface.
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 16,
                spreadRadius: 2,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: GlassSurface(
            blurSigma: 10,
            fillColor: AppColors.surface.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: AppColors.border.withValues(alpha: 0.2),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  if (showBackToMydia)
                    NavItem(
                      icon: Icons.arrow_back_rounded,
                      selectedIcon: Icons.arrow_back_rounded,
                      label: 'Mydia',
                      isSelected: false,
                      onTap: navigateToMydiaApp,
                    ),
                  NavItem(
                    icon: Icons.home_outlined,
                    selectedIcon: Icons.home_rounded,
                    label: 'Home',
                    isSelected: builtinDestinations
                        .firstWhere((d) => d.id == 'home')
                        .matches(location),
                    isDisabled: isOffline,
                    onTap: () => onNavigate('/'),
                  ),
                  NavItem(
                    icon: Icons.movie_outlined,
                    selectedIcon: Icons.movie_rounded,
                    label: 'Movies',
                    isSelected: location.startsWith('/movies'),
                    isDisabled: isOffline,
                    onTap: () => onNavigate('/movies'),
                  ),
                  NavItem(
                    icon: Icons.tv_outlined,
                    selectedIcon: Icons.tv_rounded,
                    label: 'Shows',
                    isSelected: location.startsWith('/shows'),
                    isDisabled: isOffline,
                    onTap: () => onNavigate('/shows'),
                  ),
                  if (isDownloadSupported)
                    NavItem(
                      icon: Icons.download_outlined,
                      selectedIcon: Icons.download_rounded,
                      label: 'Downloads',
                      isSelected: location.startsWith('/downloads'),
                      onTap: () => onNavigate('/downloads'),
                    )
                  else
                    NavItem(
                      icon: Icons.favorite_outline_rounded,
                      selectedIcon: Icons.favorite_rounded,
                      label: 'Favorites',
                      isSelected: location.startsWith('/favorites'),
                      isDisabled: isOffline,
                      onTap: () => onNavigate('/favorites'),
                    ),
                  SettingsNavItem(
                    isSelected: location.startsWith('/settings'),
                    isDisabled: isOffline,
                    onTap: () => onNavigate('/settings'),
                  ),
                ],
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
