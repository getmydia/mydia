import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/window/window_controller.dart';
import '../../../core/window/window_maximized.dart';

/// The strip along the top of an undecorated window that behaves like a
/// title bar: drag to move, double-click to toggle maximize.
///
/// Full width rather than only the gap beside the buttons, so any empty
/// space in the row that mounts it is a drag handle. `DesktopWindowChrome`
/// no longer mounts one of these itself: dragging is `WindowTitleRow`'s job
/// now, one per screen, sized to `WindowChromeInsets.height` rather than the
/// fixed `kLinuxWindowChromeHeight` this file used to reserve, so the same
/// band also fits the macOS title bar. The Linux button corners it used to
/// share the strip with are drawn separately, in `DesktopWindowChrome`, and
/// no longer need this widget at all.
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
    this.onDoubleTap,
  }) : _maximized = maximized;

  final WindowController controller;
  final double height;

  /// Injected by tests. Defaults to the app-wide [windowMaximized] signal.
  final ValueListenable<bool>? _maximized;

  /// Overrides the band's own double-tap handling.
  ///
  /// Null keeps this widget's maximize/unmaximize toggle, which is what
  /// every platform without a competing native double-click handler wants
  /// (Linux, where this widget's own gesture is the only thing that ever
  /// sees the click). `WindowTitleRow` passes a non-null callback on macOS,
  /// where AppKit already zooms the window on every double-click in the
  /// title bar band on its own; running this widget's toggle *as well*
  /// would fight that native zoom instead of replacing it. See
  /// `title_bar_double_click.dart`.
  final VoidCallback? onDoubleTap;

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
          onDoubleTap: onDoubleTap ??
              () => _run(
                    isMaximized
                        ? controller.unmaximize()
                        : controller.maximize(),
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
