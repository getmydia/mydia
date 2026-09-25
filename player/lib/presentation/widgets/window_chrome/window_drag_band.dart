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
    this.onPointerDown,
  }) : _maximized = maximized;

  final WindowController controller;
  final double height;

  /// Injected by tests. Defaults to the app-wide [windowMaximized] signal.
  final ValueListenable<bool>? _maximized;

  /// Overrides the band's own double-tap handling.
  ///
  /// Ignored whenever [onPointerDown] is supplied -- the two are the band's
  /// two mutually exclusive ways of reporting the same empty-space click, one
  /// per platform. Null (and no [onPointerDown] either) keeps this widget's
  /// maximize/unmaximize toggle, which is what every platform without a
  /// competing native double-click handler wants (Linux, where this widget's
  /// own gesture is the only thing that ever sees the click).
  final VoidCallback? onDoubleTap;

  /// Reports every raw pointer-down on empty band space, bypassing Flutter's
  /// gesture arena entirely, and suppresses [onDoubleTap] (and this widget's
  /// own maximize toggle) while it is supplied.
  ///
  /// `WindowTitleRow` passes this on macOS instead of [onDoubleTap]. There,
  /// AppKit -- not Flutter -- is the one deciding whether two clicks make a
  /// double-click, timed against the user's own System Settings
  /// double-click interval rather than Flutter's fixed `kDoubleTapTimeout`
  /// and `kDoubleTapSlop`. A `Listener` sees a pointer down the instant it
  /// happens and never joins the gesture arena, so it cannot be starved by
  /// either limit the way `GestureDetector.onDoubleTap` can. Native code
  /// (`MainFlutterWindow.sendEvent`) already knows the true `clickCount` for
  /// the down that started the gesture in progress; this only has to tell it
  /// a down landed on empty band space, once per down, so native can decide
  /// whether to run the title bar action. See `title_bar_double_click.dart`.
  final VoidCallback? onPointerDown;

  @override
  Widget build(BuildContext context) {
    final reportsPointerDown = onPointerDown != null;
    return ValueListenableBuilder<bool>(
      valueListenable: _maximized ?? windowMaximized,
      builder: (context, isMaximized, _) => SizedBox(
        height: height,
        width: double.infinity,
        child: Listener(
          onPointerDown: reportsPointerDown ? (_) => onPointerDown!() : null,
          child: GestureDetector(
            // Opaque so the band collects gestures over transparent content,
            // which is all of it: this widget paints nothing.
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _run(controller.startDragging(), 'drag'),
            onDoubleTap: reportsPointerDown
                ? null
                : onDoubleTap ??
                    () => _run(
                          isMaximized
                              ? controller.unmaximize()
                              : controller.maximize(),
                          'double-tap maximize',
                        ),
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
