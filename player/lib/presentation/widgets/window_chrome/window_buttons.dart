import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/window/decoration_layout.dart';
import '../../../core/window/window_controller.dart';
import '../../../core/window/window_maximized.dart';
import 'window_button.dart';

/// One side's worth of window buttons.
///
/// Renders [buttons] in the order given. The caller decides which side this
/// is by where it positions the widget; a `Row` inside a `Directionality`
/// then mirrors under RTL for free, which is what GTK does.
class WindowButtons extends StatelessWidget {
  const WindowButtons({
    super.key,
    required this.buttons,
    required this.controller,
    ValueListenable<bool>? maximized,
  }) : _maximized = maximized;

  final List<WindowButton> buttons;
  final WindowController controller;

  /// Injected by tests. Defaults to the app-wide [windowMaximized] signal.
  final ValueListenable<bool>? _maximized;

  @override
  Widget build(BuildContext context) {
    if (buttons.isEmpty) return const SizedBox.shrink();

    return ValueListenableBuilder<bool>(
      valueListenable: _maximized ?? windowMaximized,
      builder: (context, isMaximized, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final button in buttons)
            Padding(
              // Keyed on the direct child of the list, not only on the button
              // inside it. `buttons` comes from GTK's layout string and can
              // reorder live, and an unkeyed `Padding` would match by position
              // and force the keyed child under it to be rebuilt rather than
              // moved. Distinct from `WindowButtonWidget.keyFor` so finders
              // addressing the button still match exactly one widget.
              key: ValueKey(button),
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: WindowButtonWidget(
                key: WindowButtonWidget.keyFor(button),
                button: button,
                isMaximized: isMaximized,
                onPressed: () => _press(button, isMaximized),
              ),
            ),
        ],
      ),
    );
  }

  /// Fire-and-forget: these run from a tap handler, where an exception would
  /// surface as a red screen. Every call goes through the [WindowController]
  /// seam, whose native half already returns a future that completes with an
  /// error rather than throwing synchronously.
  void _press(WindowButton button, bool isMaximized) {
    final Future<void> action = switch (button) {
      WindowButton.minimize => controller.minimize(),
      WindowButton.maximize =>
        isMaximized ? controller.unmaximize() : controller.maximize(),
      WindowButton.close => controller.close(),
    };
    action.catchError(
      (Object e) => debugPrint('[WindowButtons] ${button.name} failed: $e'),
    );
  }
}
