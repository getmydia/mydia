import 'dart:ui';

/// The slice of the native window this module needs.
///
/// Narrow on purpose: `WindowGeometryController`, `PlayerWindowSizer` and the
/// window chrome widgets talk to this instead of nativeapi's `Window`, which
/// lets their tests run with fakes and no native library. See
/// `desktop_window_native.dart`.
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
