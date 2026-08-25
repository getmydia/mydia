import 'dart:ui';

/// Which window edge or corner a resize drag started from.
///
/// Mirrors `window_manager`'s `ResizeEdge`, redeclared here so this file goes
/// on importing nothing but `dart:ui`. That is the point of the seam: reading
/// the `windowManager` getter constructs a `WindowManager._()` which calls
/// `setMethodCallHandler` before a Flutter binding may exist, so a test that
/// only wanted the enum would assert-fail. `WindowManagerController` maps
/// between the two.
enum WindowEdge {
  top,
  bottom,
  left,
  right,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

/// The slice of `window_manager` this module needs.
///
/// Narrow on purpose: `WindowGeometryController`, `PlayerWindowSizer` and the
/// window chrome widgets talk to this instead of the `windowManager`
/// singleton, which lets their tests run with no Flutter binding. Reading the
/// `windowManager` getter constructs a `WindowManager._()` that calls
/// `setMethodCallHandler` before a binding may exist, which is an assertion
/// failure. See `desktop_window_native.dart`.
abstract interface class WindowController {
  Future<Rect> getBounds();
  Future<void> setBounds(Rect bounds);
  Future<bool> isMaximized();
  Future<bool> isFullScreen();
  Future<void> maximize();
  Future<void> unmaximize();
  Future<void> minimize();
  Future<void> close();
  Future<void> setMinimumSize(Size size);

  /// Hands the drag to the window manager, which keeps its own edge snapping.
  Future<void> startDragging();

  /// Hands a resize drag to the window manager from the given edge.
  Future<void> startResizing(WindowEdge edge);
}
