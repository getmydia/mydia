import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'window_controller.dart';
import 'window_maximized.dart';

/// Keeps [windowMaximized] in step with the OS window.
///
/// Takes a [WindowController] rather than reading the `windowManager`
/// singleton, matching `WindowFullscreenController`: reading that getter
/// constructs a `WindowManager._()` which calls `setMethodCallHandler` before
/// a Flutter binding may exist, so tests that touch it assert-fail.
class WindowMaximizedController with WindowListener {
  WindowMaximizedController({
    required WindowController window,
    ValueNotifier<bool>? signal,
  })  : _window = window,
        _signal = signal ?? windowMaximizedSignal;

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
