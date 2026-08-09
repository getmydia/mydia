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

  const SidebarRow({
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
  State<SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<SidebarRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.isSelected && !widget.isDisabled;
    final iconColor = widget.isDisabled
        ? AppColors.textDisabled
        : isSelected
            ? AppColors.primary
            : _isHovered
                ? AppColors.textPrimary
                : AppColors.textSecondary;
    final textColor = widget.isDisabled
        ? AppColors.textDisabled
        : isSelected
            ? AppColors.textPrimary
            : _isHovered
                ? AppColors.textPrimary
                : AppColors.textSecondary;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: widget.isDisabled
          ? SystemMouseCursors.forbidden
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
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
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
