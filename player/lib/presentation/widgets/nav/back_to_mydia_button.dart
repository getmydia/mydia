import 'package:flutter/material.dart';

import '../../../core/config/web_config.dart';
import '../../../core/theme/colors.dart';
import '../focus_highlight.dart';
import 'rail_scope.dart';

/// Button to navigate back to the main Mydia app.
/// Shown when the player is running in embed mode.
class BackToMydiaButton extends StatefulWidget {
  const BackToMydiaButton({super.key});

  @override
  State<BackToMydiaButton> createState() => _BackToMydiaButtonState();
}

class _BackToMydiaButtonState extends State<BackToMydiaButton> {
  bool _isHovered = false;

  /// The rail form: the arrow in the standard icon box, the words beside it.
  Widget _buildRail(RailScope rail) {
    return RailEntry(
      tooltip: 'Back to Mydia',
      labelsVisible: rail.labelsVisible,
      onTap: navigateToMydiaApp,
      iconBox: const FocusHighlight(
        onActivate: navigateToMydiaApp,
        borderRadius: BorderRadius.all(Radius.circular(12)),
        child: Center(
          child: Icon(
            Icons.arrow_back_rounded,
            size: 22,
            color: AppColors.textSecondary,
          ),
        ),
      ),
      label: const Text(
        'Back to Mydia',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rail = RailScope.maybeOf(context);
    if (rail != null) return _buildRail(rail);
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: navigateToMydiaApp,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: _isHovered
                ? AppColors.surfaceVariant.withValues(alpha: 0.5)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                Icons.arrow_back_rounded,
                size: 20,
                color: _isHovered ? AppColors.primary : AppColors.textSecondary,
              ),
              const SizedBox(width: 12),
              Text(
                'Back to Mydia',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: _isHovered
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
