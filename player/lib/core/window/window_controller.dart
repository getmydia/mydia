import 'dart:ui';

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

  /// Constrains user resizes to [aspectRatio] (width / height). `0` removes
  /// the constraint.
  Future<void> setAspectRatio(double aspectRatio);

  /// Hands the drag to the window manager, which keeps its own edge snapping.
  Future<void> startDragging();
}
