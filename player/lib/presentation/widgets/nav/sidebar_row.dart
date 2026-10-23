import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/palette.dart';
import '../focus_highlight.dart';
import 'rail_scope.dart';

/// Individual sidebar navigation item
class SidebarRow extends StatefulWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool isSelected;
  final bool isDisabled;
  final VoidCallback onTap;
  final Widget? badge;

  /// Whether this row may be reordered or hidden. False for anchors.
  final bool canCustomise;

  /// Invoked when the user chooses Hide from the overflow menu.
  final VoidCallback? onHide;

  /// Invoked when the user chooses Edit. Null for builtins.
  final VoidCallback? onEdit;

  /// Invoked when the user chooses Delete. Null for builtins.
  final VoidCallback? onDelete;

  /// Whether the sidebar is in edit mode.
  ///
  /// Suppresses the tap handler, the overflow menu, and the hover and
  /// long-press reveal that opens it. Navigation is suspended across the whole
  /// sidebar while editing, so a mistimed tap cannot navigate away mid-drag.
  final bool isEditing;

  /// Whether the user has hidden this row.
  ///
  /// Only ever true while editing, because edit mode is the only place hidden
  /// rows render at all.
  final bool isHidden;

  /// Rendered in the trailing slot in place of the overflow menu while editing.
  ///
  /// The parent supplies it because building a `ReorderableDragStartListener`
  /// needs the item's index, which belongs to the list rather than the row.
  final Widget? editingTrailing;

  /// Optional externally-owned node for this row.
  ///
  /// The shell needs one on the selected row so it can move focus into the
  /// sidebar deliberately when a viewer presses left at the content's edge —
  /// the traversal policy's geometric search cannot find it from the content
  /// region, which is the whole reason the boundary is explicit.
  final FocusNode? focusNode;

  const SidebarRow({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.isDisabled = false,
    this.badge,
    this.canCustomise = false,
    this.onHide,
    this.onEdit,
    this.onDelete,
    this.isEditing = false,
    this.isHidden = false,
    this.editingTrailing,
    this.focusNode,
  });

  @override
  State<SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<SidebarRow> {
  bool _isHovered = false;
  bool _isLongPressed = false;

  static const _menuWidth = 36.0;

  /// Row height at text scale 1.0: iOS list density, and the 44pt touch
  /// target. Larger text grows the row.
  static const _rowHeight = 44.0;

  /// The rail's geometry: a 48x48 icon box with the label beside it. The
  /// selection fill and ring wrap the icon box, which is the part that stays
  /// on screen while the rail is collapsed.
  Widget _buildRail(RailScope rail) {
    final palette = context.palette;
    final isSelected = widget.isSelected && !widget.isDisabled;
    return RailEntry(
      tooltip: widget.label,
      labelsVisible: rail.labelsVisible,
      onTap: widget.isDisabled ? null : widget.onTap,
      iconBox: FocusHighlight(
        focusNode: widget.focusNode,
        onActivate: widget.isDisabled ? null : widget.onTap,
        borderRadius:
            const BorderRadius.all(Radius.circular(AppTheme.radiusNavItem)),
        child: Container(
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.white.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTheme.radiusNavItem),
            border: isSelected
                ? Border.all(color: palette.primary, width: 2)
                : null,
          ),
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Icon(
                isSelected ? widget.selectedIcon : widget.icon,
                size: 22,
                color: widget.isDisabled
                    ? palette.textDisabled
                    : isSelected
                        ? palette.textPrimary
                        : palette.textSecondary,
              ),
              if (widget.badge != null)
                Positioned(top: 8, right: 8, child: widget.badge!),
            ],
          ),
        ),
      ),
      label: Text(
        widget.label,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: TextStyle(
          fontSize: 15,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
          color: widget.isDisabled
              ? palette.textDisabled
              : isSelected
                  ? palette.textPrimary
                  : palette.textSecondary,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final rail = RailScope.maybeOf(context);
    if (rail != null && !widget.isEditing) return _buildRail(rail);
    final isSelected = widget.isSelected && !widget.isDisabled;

    // An anchor cannot be reordered or hidden, so while editing it reads as
    // locked: dimmed the same way a hidden row is, plus the lock glyph
    // `SidebarContent` adds in its trailing slot.
    final isLockedWhileEditing = widget.isEditing && !widget.canCustomise;

    final isDimmed =
        widget.isDisabled || widget.isHidden || isLockedWhileEditing;
    final iconColor = isDimmed
        ? palette.textDisabled
        : isSelected
            ? palette.primary
            : _isHovered
                ? palette.textPrimary
                : palette.textSecondary;
    final textColor = isDimmed
        ? palette.textDisabled
        : isSelected
            ? palette.textPrimary
            : _isHovered
                ? palette.textPrimary
                : palette.textSecondary;

    final showMenu = widget.canCustomise &&
        !widget.isEditing &&
        (_isHovered || _isLongPressed);

    // In edit mode the 36px slot the overflow menu already reserves becomes
    // the grip or restore slot, so nothing shifts between the two modes.
    final Widget? trailing = widget.isEditing
        ? widget.editingTrailing
        : (widget.canCustomise ? _overflowMenu(showMenu: showMenu) : null);

    return FocusHighlight(
      focusNode: widget.focusNode,
      onActivate: widget.isEditing ? null : widget.onTap,
      // Matches the pill `BoxDecoration.borderRadius` below: the ring traces
      // that exact rectangle, so the two radii must move together.
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() {
          _isHovered = false;
          _isLongPressed = false;
        }),
        // Scoped to anchors only: every row's tap is suppressed while
        // editing, but only an anchor's cursor changes here. A customisable
        // row is still draggable and its overflow menu still exists just
        // outside edit mode, so a click cursor there is arguably still wrong
        // too, left alone as a separate call, not part of this fix.
        cursor: widget.isDisabled
            ? SystemMouseCursors.forbidden
            : isLockedWhileEditing
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.isEditing ? null : widget.onTap,
          onLongPress: widget.canCustomise && !widget.isEditing
              ? () => setState(() => _isLongPressed = true)
              : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            constraints: const BoxConstraints(minHeight: _rowHeight),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: widget.isDisabled
                  ? Colors.transparent
                  : isSelected
                      ? palette.primary.withValues(alpha: 0.12)
                      : _isHovered
                          ? palette.surfaceVariant.withValues(alpha: 0.3)
                          : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(
                      isSelected ? widget.selectedIcon : widget.icon,
                      size: 22,
                      color: iconColor,
                    ),
                    if (widget.badge != null)
                      Positioned(
                        top: -3,
                        right: -3,
                        child: widget.badge!,
                      ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    widget.label,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: textColor,
                      decoration:
                          widget.isHidden ? TextDecoration.lineThrough : null,
                      decorationColor: palette.textDisabled,
                    ),
                  ),
                ),
                // A fixed height too: unconstrained, the menu's IconButton
                // pads itself to 48 and the row grows to 72.
                // The slot stays reserved for the whole time the row is
                // editing, even when the caller withholds editingTrailing, so
                // the row's width never shifts mid-edit.
                if (trailing != null || widget.isEditing)
                  SizedBox(
                    width: _menuWidth,
                    height: _rowHeight,
                    child: Center(child: trailing ?? const SizedBox.shrink()),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _overflowMenu({required bool showMenu}) {
    // PopupMenuButton wraps a Material IconButton, whose canRequestFocus is
    // just onPressed != null: neither Opacity nor IgnorePointer removes a
    // widget from focus traversal, so a hidden button would still be a live,
    // invisible tab stop. ExcludeFocus is what actually pulls it out of
    // traversal while hidden; on a TV, showMenu is always false (it is
    // hover- and edit-driven, and a TV has no hover), so the button drops
    // out entirely there. Desktop keyboard users keep it once it is shown.
    return ExcludeFocus(
      excluding: !showMenu,
      child: Opacity(
        opacity: showMenu ? 1 : 0,
        child: IgnorePointer(
          ignoring: !showMenu,
          child: PopupMenuButton<String>(
            padding: EdgeInsets.zero,
            icon: Icon(
              Icons.more_vert,
              size: 20,
              color: context.palette.textSecondary,
            ),
            onSelected: (value) {
              setState(() => _isLongPressed = false);
              switch (value) {
                case 'hide':
                  widget.onHide?.call();
                case 'edit':
                  widget.onEdit?.call();
                case 'delete':
                  widget.onDelete?.call();
              }
            },
            onCanceled: () => setState(() => _isLongPressed = false),
            itemBuilder: (context) => [
              if (widget.onHide != null)
                const PopupMenuItem(value: 'hide', child: Text('Hide')),
              if (widget.onEdit != null)
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
              if (widget.onDelete != null)
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ),
      ),
    );
  }
}
