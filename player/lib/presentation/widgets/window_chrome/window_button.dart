import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../core/window/decoration_layout.dart';

/// A single window-manager button, drawn by Flutter.
///
/// GTK draws no titlebar (`MydiaNoTitlebar` in `my_application.cc`), so
/// these are the only close, minimize and maximize affordances the window
/// has, and the hit target is deliberately larger than the glyph.
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

  /// Edge length of the button's hit target on Linux, in logical pixels. Sized to sit
  /// inside `kLinuxWindowChromeHeight` with room to breathe.
  static const double linuxSize = 28;

  /// Backward-compatible alias for [linuxSize].
  static const double size = linuxSize;

  /// Dimensions for Windows 11 Fluent caption buttons.
  static const double windowsWidth = 46.0;
  static const double windowsHeight = 40.0;

  /// Stable key per button, so tests address them without depending on
  /// glyph choice or layout order.
  static Key keyFor(WindowButton button) => Key('window-button-${button.name}');

  @override
  State<WindowButtonWidget> createState() => _WindowButtonWidgetState();
}

class _WindowButtonWidgetState extends State<WindowButtonWidget> {
  bool _hovered = false;

  bool get _isWindows => defaultTargetPlatform == TargetPlatform.windows;

  double get _width => _isWindows
      ? WindowButtonWidget.windowsWidth
      : WindowButtonWidget.linuxSize;
  double get _height => _isWindows
      ? WindowButtonWidget.windowsHeight
      : WindowButtonWidget.linuxSize;
  BorderRadius get _borderRadius =>
      _isWindows ? BorderRadius.zero : BorderRadius.circular(6);

  IconData get _icon => switch (widget.button) {
        WindowButton.minimize => Icons.remove,
        WindowButton.maximize =>
          widget.isMaximized ? Icons.filter_none : Icons.crop_square,
        WindowButton.close => Icons.close,
      };

  /// Close goes red on hover (#E81123 on Windows Fluent, AppColors.error on Linux).
  /// The other two take a subtle fill (0x1AFFFFFF on Windows, surfaceVariant on Linux).
  Color get _hoverColor {
    if (widget.button == WindowButton.close) {
      return _isWindows ? const Color(0xFFE81123) : AppColors.error;
    }
    return _isWindows ? const Color(0x1AFFFFFF) : AppColors.surfaceVariant;
  }

  double get _iconSize =>
      _isWindows && widget.button == WindowButton.maximize ? 13 : 15;

  Color get _iconColor {
    if (_hovered && widget.button == WindowButton.close) {
      return _isWindows ? Colors.white : AppColors.textPrimary;
    }
    return AppColors.textSecondary;
  }

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
            width: _width,
            height: _height,
            decoration: BoxDecoration(
              color: _hovered ? _hoverColor : Colors.transparent,
              borderRadius: _borderRadius,
            ),
            child: Icon(
              _icon,
              size: _iconSize,
              color: _iconColor,
            ),
          ),
        ),
      ),
    );
  }
}
