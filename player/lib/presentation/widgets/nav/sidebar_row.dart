import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';

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
  });

  @override
  State<SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<SidebarRow> {
  bool _isHovered = false;
  bool _isLongPressed = false;

  static const _menuWidth = 36.0;

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.isSelected && !widget.isDisabled;
    final iconColor = widget.isDisabled || widget.isHidden
        ? AppColors.textDisabled
        : isSelected
            ? AppColors.primary
            : _isHovered
                ? AppColors.textPrimary
                : AppColors.textSecondary;
    final textColor = widget.isDisabled || widget.isHidden
        ? AppColors.textDisabled
        : isSelected
            ? AppColors.textPrimary
            : _isHovered
                ? AppColors.textPrimary
                : AppColors.textSecondary;

    final showMenu = widget.canCustomise &&
        !widget.isEditing &&
        (_isHovered || _isLongPressed);

    // In edit mode the 36px slot the overflow menu already reserves becomes
    // the grip or restore slot, so nothing shifts between the two modes.
    final Widget? trailing = widget.isEditing
        ? widget.editingTrailing
        : (widget.canCustomise ? _overflowMenu(showMenu: showMenu) : null);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() {
        _isHovered = false;
        _isLongPressed = false;
      }),
      cursor: widget.isDisabled
          ? SystemMouseCursors.forbidden
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.isEditing ? null : widget.onTap,
        onLongPress: widget.canCustomise && !widget.isEditing
            ? () => setState(() => _isLongPressed = true)
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: widget.isDisabled
                ? Colors.transparent
                : isSelected
                    ? AppColors.primary.withValues(alpha: 0.12)
                    : _isHovered
                        ? AppColors.surfaceVariant.withValues(alpha: 0.3)
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
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: textColor,
                    decoration:
                        widget.isHidden ? TextDecoration.lineThrough : null,
                    decorationColor: AppColors.textDisabled,
                  ),
                ),
              ),
              if (trailing != null)
                SizedBox(
                  width: _menuWidth,
                  child: Center(child: trailing),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _overflowMenu({required bool showMenu}) {
    return Opacity(
      opacity: showMenu ? 1 : 0,
      child: IgnorePointer(
        ignoring: !showMenu,
        child: PopupMenuButton<String>(
          padding: EdgeInsets.zero,
          icon: Icon(
            Icons.more_vert,
            size: 20,
            color: AppColors.textSecondary,
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
    );
  }
}
