import 'package:flutter/foundation.dart';

import 'window_controller.dart';
import 'window_event_listener.dart';
import 'window_maximized.dart';

/// Keeps [windowMaximized] in step with the OS window.
///
/// Takes a [WindowController] rather than the native window, matching
/// `WindowFullscreenController`, so its tests need no native library.
class WindowMaximizedController with WindowEventListener {
  WindowMaximizedController({
    required this._window,
    ValueNotifier<bool>? signal,
  }) : _signal = signal ?? windowMaximizedSignal;

  final WindowController _window;
  final ValueNotifier<bool> _signal;

  /// Reads the window's current state once, for the case where the app is
  /// launched into an already-maximized window and no event ever fires.
  ///
  /// Never throws: startup must not fail over window chrome, and a failed
  /// read leaves the signal at `false`, which only costs a wrong maximize
  /// glyph until the next real event corrects it.
  Future<void> seed() async {
    try {
      _signal.value = await _window.isMaximized();
    } catch (e) {
      debugPrint('[WindowMaximized] Failed to read maximized state: $e');
    }
  }

  @override
  void onWindowMaximize() => _signal.value = true;

  @override
  void onWindowUnmaximize() => _signal.value = false;
}
