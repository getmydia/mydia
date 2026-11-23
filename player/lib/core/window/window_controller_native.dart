import 'dart:ui';

import 'package:window_manager/window_manager.dart';

import 'native_window_host.dart';
import 'window_controller.dart';

/// The real window, behind the [WindowController] seam.
///
/// Delegation only. Every branch worth testing lives above this line.
/// nativeapi's calls are synchronous; wrapping each body in an `async`
/// function turns a throw (no window yet, no native library) into a failed
/// future, which every caller already handles.
class WindowManagerController implements WindowController {
  const WindowManagerController();

  Window get _window => NativeWindowHost.instance.requireWindow();

  @override
  Future<Rect> getBounds() async => _window.bounds.toRect();

  @override
  Future<void> setBounds(Rect bounds) async =>
      _window.bounds = bounds.toNative();

  @override
  Future<bool> isMaximized() async => _window.isMaximized;

  @override
  Future<bool> isFullScreen() async => _window.isFullScreen;

  @override
  Future<void> maximize() async => _window.maximize();

  @override
  Future<void> unmaximize() async => _window.unmaximize();

  @override
  Future<void> minimize() async => _window.minimize();

  @override
  Future<void> close() async => _window.close();

  @override
  Future<void> setMinimumSize(Size size) async =>
      _window.minimumSize = size.toNative();

  @override
  Future<void> setAspectRatio(double aspectRatio) async =>
      _window.aspectRatio = aspectRatio;

  @override
  Future<void> startDragging() async => _window.startDragging();
}
