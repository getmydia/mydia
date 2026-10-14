import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/colors.dart';
import 'focus_highlight.dart';

/// The detail pages' Play / Resume control: the design system's white primary
/// button, a play icon and a label on a white pill.
///
/// Gold stays reserved for progress, selection, focus rings and badges, so
/// this never paints [AppColors.primary]. A null [onPressed] renders the
/// disabled surface and takes no focus, the same as the control it replaced.
class PrimaryPlayButton extends StatefulWidget {
  const PrimaryPlayButton({
    super.key,
    required this.onPressed,
    this.label = 'Play',
    this.iconOnly = false,
  });

  /// Drop the text for width-bounded layouts. The label stays as the
  /// accessibility name.
  final bool iconOnly;

  final VoidCallback? onPressed;

  /// "Play", or "Resume" when the item has saved progress.
  final String label;

  /// The control's height, comfortably above the 48 px touch target.
  static const double height = 48;

  @override
  State<PrimaryPlayButton> createState() => _PrimaryPlayButtonState();
}

class _PrimaryPlayButtonState extends State<PrimaryPlayButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 100),
    vsync: this,
  );
  late final Animation<double> _scale = Tween<double>(begin: 1.0, end: 0.95)
      .animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  static const _radius =
      BorderRadius.all(Radius.circular(AppTheme.radiusButton));

  bool get _enabled => widget.onPressed != null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final foreground = _enabled ? AppColors.background : AppColors.textDisabled;
    return ScaleTransition(
      scale: _scale,
      child: FocusHighlight(
        onActivate: widget.onPressed,
        borderRadius: _radius,
        child: Material(
          color: _enabled ? Colors.white : AppColors.surfaceVariant,
          borderRadius: _radius,
          child: InkWell(
            borderRadius: _radius,
            // FocusHighlight above is the single focus stop for this button.
            // InkWell would otherwise register a second, invisible one nested
            // inside it, so a D-pad user would press twice to clear it.
            canRequestFocus: false,
            onTap: widget.onPressed,
            onTapDown: _enabled ? (_) => _controller.forward() : null,
            onTapUp: _enabled ? (_) => _controller.reverse() : null,
            onTapCancel: _enabled ? () => _controller.reverse() : null,
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(minHeight: PrimaryPlayButton.height),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: widget.iconOnly ? 11 : 22,
                ),
                child: Semantics(
                  label: widget.iconOnly ? widget.label : null,
                  excludeSemantics: widget.iconOnly,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.play_arrow_rounded,
                        size: 26,
                        color: foreground,
                      ),
                      if (!widget.iconOnly) ...[
                        const SizedBox(width: 8),
                        Text(
                          widget.label,
                          style: TextStyle(
                            fontFamily: AppTheme.displayFamily,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: foreground,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
