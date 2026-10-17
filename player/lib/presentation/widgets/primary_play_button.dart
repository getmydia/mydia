import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/palette.dart';
import 'focus_highlight.dart';

/// The detail pages' Play / Resume control: the design system's white primary
/// button, a play icon and a label on a white pill.
///
/// Gold stays reserved for progress, selection, focus rings and badges, so
/// this never paints the palette's primary. A null [onPressed] renders the
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

  /// Space between the pill and its focus ring.
  static const double ringGap = 3;

  /// Finder handle for the white pill itself.
  static const pillKey = ValueKey('primary-play-pill');

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
  static const _ringRadius = BorderRadius.all(
      Radius.circular(AppTheme.radiusButton + PrimaryPlayButton.ringGap));

  bool get _enabled => widget.onPressed != null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final foreground = _enabled ? palette.background : palette.textDisabled;
    return ScaleTransition(
      scale: _scale,
      child: FocusHighlight(
        onActivate: widget.onPressed,
        // A gold ring in the gap around the pill: the default white ring would
        // vanish against the white fill if it were drawn on the pill itself.
        borderRadius: _ringRadius,
        ringColor: palette.primary,
        ringOpacity: 1,
        child: Padding(
          padding: const EdgeInsets.all(PrimaryPlayButton.ringGap),
          child: Material(
            key: PrimaryPlayButton.pillKey,
            color: _enabled ? Colors.white : palette.surfaceVariant,
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
      ),
    );
  }
}
