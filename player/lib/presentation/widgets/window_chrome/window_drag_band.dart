import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/window/window_controller.dart';
import '../../../core/window/window_maximized.dart';

/// The strip along the top of an undecorated window that behaves like a
/// title bar: drag to move, double-click to toggle maximize.
///
/// Full width rather than only the gap beside the buttons. See
/// `kLinuxWindowChromeHeight` for why the band is uniform.
///
/// Paints nothing. App content runs underneath it, which is the whole point
/// of moving the decorations inside the window, so this only collects
/// gestures.
class WindowDragBand extends StatelessWidget {
  const WindowDragBand({
    super.key,
    required this.controller,
    required this.height,
    ValueListenable<bool>? maximized,
  }) : _maximized = maximized;

  final WindowController controller;
  final double height;

  /// Injected by tests. Defaults to the app-wide [windowMaximized] signal.
  final ValueListenable<bool>? _maximized;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _maximized ?? windowMaximized,
      builder: (context, isMaximized, _) => SizedBox(
        height: height,
        width: double.infinity,
        child: GestureDetector(
          // Opaque so the band collects gestures over transparent content,
          // which is all of it: this widget paints nothing.
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => _run(controller.startDragging(), 'drag'),
          onDoubleTap: () => _run(
            isMaximized ? controller.unmaximize() : controller.maximize(),
            'double-tap maximize',
          ),
        ),
      ),
    );
  }

  /// Fire-and-forget: these run from a gesture handler, where an exception
  /// would surface as a red screen.
  void _run(Future<void> action, String label) {
    action.catchError(
      (Object e) => debugPrint('[WindowDragBand] $label failed: $e'),
    );
  }
}
