import 'dart:ui';

import 'package:window_manager/window_manager.dart';

import 'mac_window_channel.dart';
import 'native_window_host.dart';
import 'window_controller.dart';

/// The real window's controller for this platform: [MacWindowChannelController]
/// on macOS, where nativeapi cannot reach the window from Dart's thread, and
/// [WindowManagerController] everywhere else.
WindowController nativeWindowController() => useMacWindowChannel
    ? MacWindowChannelController()
    : const WindowManagerController();

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

/// The macOS window, through `WindowPlugin` on the main thread. See
/// `mac_window_channel.dart` for why.
///
/// Every call fails its future when the plugin answers an error (no window
/// yet, or no plugin in a plain `flutter test`), which every caller already
/// handles.
class MacWindowChannelController implements WindowController {
  MacWindowChannelController([MacWindowChannel? channel])
    : _channel = channel ?? MacWindowChannel.instance;

  final MacWindowChannel _channel;

  @override
  Future<Rect> getBounds() async =>
      decodeRect(await _channel.invoke<Object?>('getBounds'));

  @override
  Future<void> setBounds(Rect bounds) =>
      _channel.invoke<void>('setBounds', encodeRect(bounds));

  @override
  Future<bool> isMaximized() async =>
      await _channel.invoke<bool>('isMaximized') ?? false;

  @override
  Future<bool> isFullScreen() async =>
      await _channel.invoke<bool>('isFullScreen') ?? false;

  @override
  Future<void> maximize() => _channel.invoke<void>('maximize');

  @override
  Future<void> unmaximize() => _channel.invoke<void>('unmaximize');

  @override
  Future<void> minimize() => _channel.invoke<void>('minimize');

  @override
  Future<void> close() => _channel.invoke<void>('close');

  @override
  Future<void> setMinimumSize(Size size) => _channel.invoke<void>(
    'setMinimumSize',
    {'width': size.width, 'height': size.height},
  );

  @override
  Future<void> setAspectRatio(double aspectRatio) =>
      _channel.invoke<void>('setAspectRatio', {'ratio': aspectRatio});

  @override
  Future<void> startDragging() => _channel.invoke<void>('startDragging');
}
