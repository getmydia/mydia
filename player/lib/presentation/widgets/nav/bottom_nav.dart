import 'package:flutter/material.dart';

import '../../../core/config/web_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/liquid_glass/glass_style.dart';
import '../../../core/theme/liquid_glass/liquid_geometry.dart';
import '../../../core/theme/palette.dart';
import '../../../domain/navigation/source_nav.dart';
import '../focus_highlight.dart';
import '../glass_surface.dart';
import '../toast/toast_obstruction.dart';
import 'dock_glass.dart';
import 'library_sheet.dart';
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

/// The source's own rows that the bar has no room for: its libraries and the
/// viewer's saved filters. Long-press on Home lists them.
List<SourceNavEntry> libraryNavEntries(List<SourceNavEntry> entries) {
  const barIds = {
    'home',
    'movies',
    'shows',
    'downloads',
    'favorites',
    'settings',
  };
  return [
    for (final e in entries)
      if (!e.anchored && !barIds.contains(e.id)) e,
  ];
}

/// Mobile bottom navigation bar
class BottomNav extends StatelessWidget {
  final String location;
  final ValueChanged<String> onNavigate;

  /// The bar's items, in order. The shell picks them from the current
  /// source's navigation (see [bottomNavEntries]).
  final List<SourceNavEntry> entries;

  /// Rows listed by a long-press on Home (see [libraryNavEntries]).
  final List<SourceNavEntry> libraryEntries;
  final bool isOffline;
  final bool showBackToMydia;

  /// The narrowest share of the bar an item may have and still show its
  /// label. Below it every item is icon-only: the selected pill and a
  /// tooltip/semantics label carry the name, and the item still fills its
  /// whole share, which stays a 48px tap target down to 320px with six items.
  static const double compactItemWidth = 56;

  const BottomNav({
    super.key,
    required this.location,
    required this.onNavigate,
    required this.entries,
    this.libraryEntries = const [],
    this.isOffline = false,
    this.showBackToMydia = false,
  });

  @override
  Widget build(BuildContext context) {
    final liquid = GlassStyle.of(context);
    final barRadius = BorderRadius.circular(
      liquid ? LiquidGeometry.tabBarHeight / 2 : AppTheme.radiusBottomBar,
    );
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
              borderRadius: barRadius,
              boxShadow: DockGlass.shadow,
            ),
            child: GlassSurface.chrome(
              opacity: DockGlass.fillOpacity,
              borderRadius: barRadius,
              border: DockGlass.border(context.palette),
              child: Padding(
                padding: liquid
                    ? const EdgeInsets.all(LiquidGeometry.tabSelectionInset)
                    : const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                // Every item takes an equal share of the bar, so the row can
                // never be wider than the bar. Where a share is too narrow for
                // a label (see [compactItemWidth]) the items drop to icons.
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final count = entries.length + (showBackToMydia ? 1 : 0);
                    final compact = count > 0 &&
                        constraints.maxWidth / count < compactItemWidth;
                    final row = Row(
                      // Liquid Glass: every item is as tall as the tallest, so
                      // the bar grows with a large text scale.
                      crossAxisAlignment: liquid
                          ? CrossAxisAlignment.stretch
                          : CrossAxisAlignment.center,
                      children: [
                        if (showBackToMydia)
                          Expanded(
                            child: NavItem(
                              icon: Icons.arrow_back_rounded,
                              selectedIcon: Icons.arrow_back_rounded,
                              label: 'Mydia',
                              isSelected: false,
                              compact: compact,
                              onTap: navigateToMydiaApp,
                            ),
                          ),
                        for (final entry in entries)
                          Expanded(
                            child: entry.id == 'settings'
                                ? SettingsNavItem(
                                    location: location,
                                    isSelected: entry.matches(location),
                                    isDisabled: isOffline,
                                    compact: compact,
                                    onTap: () => onNavigate(entry.route),
                                  )
                                : NavItem(
                                    icon: entry.icon,
                                    selectedIcon: entry.selectedIcon,
                                    label: entry.shortLabel ?? entry.label,
                                    isSelected: entry.matches(location),
                                    isDisabled:
                                        isOffline && entry.id != 'downloads',
                                    compact: compact,
                                    onTap: () => onNavigate(entry.route),
                                    onLongPress: entry.id == 'home' &&
                                            libraryEntries.isNotEmpty
                                        ? () => showLibrarySheet(
                                              context,
                                              entries: libraryEntries,
                                              onNavigate: onNavigate,
                                            )
                                        : null,
                                  ),
                          ),
                      ],
                    );
                    // Nav items must stay intrinsic-safe (no LayoutBuilder).
                    return liquid ? IntrinsicHeight(child: row) : row;
                  },
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
  final VoidCallback? onLongPress;
  final Widget? badge;

  /// Icon only, with [label] as tooltip and semantics. See
  /// [BottomNav.compactItemWidth].
  final bool compact;

  const NavItem({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.onLongPress,
    this.isDisabled = false,
    this.badge,
    this.compact = false,
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
    final liquid = GlassStyle.of(context);
    final pillRadius = liquid ? LiquidGeometry.tabSelectionHeight / 2 : 12.0;
    final palette = context.palette;
    final effectiveColor = widget.isDisabled
        ? palette.textDisabled
        : widget.isSelected
            ? palette.primary
            : palette.textSecondary;

    final item = FocusHighlight(
      onActivate: widget.onTap,
      // Matches the pill `BoxDecoration.borderRadius` below: the ring traces
      // that exact rectangle, so the two radii must move together.
      borderRadius: BorderRadius.circular(pillRadius),
      child: GestureDetector(
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        onLongPress: widget.onLongPress,
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            // 12 + 24 + 12 keeps the icon-only item a 48px tap target. On Liquid
            // Glass the item is the kit's 54 tall selection pill instead, and
            // its content centres in it. 54 is a minimum so a large text scale
            // grows the item and the bar with it.
            constraints: liquid
                ? const BoxConstraints(
                    minHeight: LiquidGeometry.tabSelectionHeight,
                  )
                : null,
            alignment: liquid ? Alignment.center : null,
            padding: EdgeInsets.symmetric(
              horizontal: 4,
              vertical: liquid ? 0 : (widget.compact ? 12 : 8),
            ),
            decoration: BoxDecoration(
              color: widget.isSelected && !widget.isDisabled
                  ? palette.primary.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(pillRadius),
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
                if (!widget.compact) ...[
                  const SizedBox(height: 4),
                  // Scales a long label down rather than overflowing.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: widget.isSelected && !widget.isDisabled
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: effectiveColor,
                      ),
                      child: Text(widget.label, maxLines: 1),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (!widget.compact) return item;
    return Tooltip(
      message: widget.label,
      child: Semantics(
        label: widget.label,
        button: true,
        selected: widget.isSelected,
        excludeSemantics: true,
        child: item,
      ),
    );
  }
}
