import 'dart:ui';

/// The slice of `window_manager` this module needs.
///
/// Narrow on purpose: `WindowGeometryController` and `PlayerWindowSizer` talk
/// to this instead of the `windowManager` singleton, which lets their tests run
/// with no Flutter binding. Reading the `windowManager` getter constructs a
/// `WindowManager._()` that calls `setMethodCallHandler` before a binding may
/// exist, which is an assertion failure — see `window_drag_service_native.dart`.
abstract interface class WindowController {
  Future<Rect> getBounds();
  Future<void> setBounds(Rect bounds);
  Future<bool> isMaximized();
  Future<bool> isFullScreen();
  Future<void> maximize();
  Future<void> setMinimumSize(Size size);
}
