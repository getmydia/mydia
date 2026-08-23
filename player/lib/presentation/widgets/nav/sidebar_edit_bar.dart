import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';

/// The bar shown below the sidebar's brand row while edit mode is active.
///
/// Presentational: it owns no state and makes no decisions. The reset
/// confirmation lives with the caller, which has the provider access to act on
/// the answer.
class SidebarEditBar extends StatelessWidget {
  const SidebarEditBar({
    super.key,
    required this.onDone,
    this.onReset,
  });

  final VoidCallback onDone;

  /// Null while the confirmation dialog does not exist yet, and in any caller
  /// that has no business offering a destructive reset. The control is omitted
  /// rather than disabled, so no commit ships a reset that skips its
  /// confirmation.
  final VoidCallback? onReset;

  /// Minimum interactive (tap/click) region for the reset control, in
  /// logical pixels. Kept at Material's 48dp-adjacent minimum touch target
  /// guidance (also WCAG 2.5.5 and Apple HIG territory) even though the
  /// glyph itself stays small — this guards a destructive action, so a
  /// cramped hit target is a real usability defect, not polish.
  static const double resetControlTapSize = 44;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Editing',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: AppColors.primary,
              ),
            ),
          ),
          if (onReset != null) ...[
            IconButton(
              onPressed: onReset,
              tooltip: 'Reset sidebar',
              iconSize: 19,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(
                width: resetControlTapSize,
                height: resetControlTapSize,
              ),
              icon: const Icon(
                Icons.settings_backup_restore_rounded,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(width: 4),
          ],
          TextButton(
            onPressed: onDone,
            style: TextButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.onPrimary,
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              shape: const StadiumBorder(),
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
