import 'package:flutter/foundation.dart';

/// Whether the OS window is maximized.
///
/// Deliberately platform-free, mirroring `window_fullscreen.dart`: this file
/// imports nothing that `window_manager` touches, so the window buttons can
/// read it without a conditional import. The half that talks to the window
/// lives in `window_maximized_controller.dart`, reachable only from
/// `desktop_window_native.dart`.
///
/// This exists rather than the maximize button polling `isMaximized()`
/// because a double-click on the drag band, a window manager keybinding and
/// a drag to the top edge all maximize the window, and a polled field never
/// learns about any of them.
final ValueNotifier<bool> windowMaximizedSignal = ValueNotifier<bool>(false);

/// Read-only view of [windowMaximizedSignal] for consumers.
ValueListenable<bool> get windowMaximized => windowMaximizedSignal;
