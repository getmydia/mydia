import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../core/window/decoration_layout.dart';

/// A single window-manager button, drawn by Flutter.
///
/// Once the GTK window is undecorated these are the only close, minimize and
/// maximize affordances the window has, so the hit target is deliberately
/// larger than the glyph.
class WindowButtonWidget extends StatefulWidget {
  const WindowButtonWidget({
    super.key,
    required this.button,
    required this.onPressed,
    this.isMaximized = false,
  });

  final WindowButton button;
  final VoidCallback onPressed;

  /// Swaps the maximize glyph for a restore glyph. Ignored by the other two
  /// buttons.
  final bool isMaximized;

  /// Edge length of the button's hit target, in logical pixels. Sized to sit
  /// inside `kLinuxWindowChromeHeight` with room to breathe.
  static const double size = 28;

  /// Stable key per button, so tests address them without depending on
  /// glyph choice or layout order.
  static Key keyFor(WindowButton button) => Key('window-button-${button.name}');

  @override
  State<WindowButtonWidget> createState() => _WindowButtonWidgetState();
}

class _WindowButtonWidgetState extends State<WindowButtonWidget> {
  bool _hovered = false;

  IconData get _icon => switch (widget.button) {
        WindowButton.minimize => Icons.remove,
        WindowButton.maximize =>
          widget.isMaximized ? Icons.filter_none : Icons.crop_square,
        WindowButton.close => Icons.close,
      };

  /// Close goes red on hover, which is the near-universal Linux convention.
  /// The other two take a neutral fill.
  Color get _hoverColor => widget.button == WindowButton.close
      ? AppColors.error
      : AppColors.surfaceVariant;

  String get _tooltip => switch (widget.button) {
        WindowButton.minimize => 'Minimize',
        WindowButton.maximize => widget.isMaximized ? 'Restore' : 'Maximize',
        WindowButton.close => 'Close',
      };

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: _tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: WindowButtonWidget.size,
            height: WindowButtonWidget.size,
            decoration: BoxDecoration(
              color: _hovered ? _hoverColor : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              _icon,
              size: 15,
              color: _hovered && widget.button == WindowButton.close
                  ? AppColors.textPrimary
                  : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
