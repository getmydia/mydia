import 'dart:ui';

import 'package:window_manager/window_manager.dart';

import 'window_controller.dart';

/// The real window, behind the [WindowController] seam.
///
/// Delegation only — every branch worth testing lives above this line.
class WindowManagerController implements WindowController {
  const WindowManagerController();

  @override
  Future<Rect> getBounds() => windowManager.getBounds();

  @override
  Future<void> setBounds(Rect bounds) => windowManager.setBounds(bounds);

  @override
  Future<bool> isMaximized() => windowManager.isMaximized();

  @override
  Future<bool> isFullScreen() => windowManager.isFullScreen();

  @override
  Future<void> maximize() => windowManager.maximize();

  @override
  Future<void> setMinimumSize(Size size) => windowManager.setMinimumSize(size);
}
