import 'package:flutter/material.dart';
import '../../core/theme/colors.dart';
import 'focus_highlight.dart';

class PlayButton extends StatefulWidget {
  final VoidCallback? onPressed;

  const PlayButton({
    super.key,
    this.onPressed,
  });

  @override
  State<PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<PlayButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  bool get _enabled => widget.onPressed != null;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.90).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static const double _size = 52.0;

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnimation,
      child: SizedBox(
        width: _size,
        height: _size,
        child: FocusHighlight(
          onActivate: widget.onPressed,
          circular: true,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // Solid primary fill to match the system's flat primary actions
              // (FilledButton, hero Play, card play overlay) — no two-hue
              // gradient.
              color: _enabled ? AppColors.primary : AppColors.surfaceVariant,
              boxShadow: _enabled
                  ? [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.4),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                // FocusHighlight above is the single focus stop for this
                // button. InkWell defaults canRequestFocus to true, which
                // would otherwise register a second, invisible focus stop
                // nested inside the first one, forcing a D-pad user to press
                // right/down twice to clear one button.
                canRequestFocus: false,
                onTap: widget.onPressed,
                onTapDown: _enabled ? (_) => _controller.forward() : null,
                onTapUp: _enabled ? (_) => _controller.reverse() : null,
                onTapCancel: _enabled ? () => _controller.reverse() : null,
                child: Center(
                  child: Padding(
                    // Slight right offset to optically center the play
                    // triangle
                    padding: const EdgeInsets.only(left: 3),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      size: 28,
                      color: _enabled ? Colors.white : AppColors.textDisabled,
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
