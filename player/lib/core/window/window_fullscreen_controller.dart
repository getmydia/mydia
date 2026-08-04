import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'window_controller.dart';
import 'window_fullscreen.dart';

/// Keeps [windowFullscreen] in step with the OS window.
///
/// Takes a [WindowController] rather than reading the `windowManager`
/// singleton, matching `WindowGeometryController`: reading that getter
/// constructs a `WindowManager._()` which calls `setMethodCallHandler` before
/// a Flutter binding may exist, so tests that touch it assert-fail.
///
/// This exists rather than reusing `PlayerScreen`'s own `_isFullscreen` field
/// because the green button, the View menu and Cmd+Ctrl+F also fullscreen the
/// window, and that field never learns about any of them.
class WindowFullscreenController with WindowListener {
  WindowFullscreenController({
    required WindowController window,
    ValueNotifier<bool>? signal,
  })  : _window = window,
        _signal = signal ?? windowFullscreenSignal;

  final WindowController _window;
  final ValueNotifier<bool> _signal;

  /// Reads the window's current state once, for the case where the app is
  /// launched into an already-fullscreen window and no event ever fires.
  ///
  /// Never throws: startup must not fail over window chrome, and a failed read
  /// leaves the signal at `false`, which only costs a 28pt inset that the next
  /// real event corrects.
  Future<void> seed() async {
    try {
      _signal.value = await _window.isFullScreen();
    } catch (e) {
      debugPrint('[WindowFullscreen] Failed to read fullscreen state: $e');
    }
  }

  @override
  void onWindowEnterFullScreen() => _signal.value = true;

  @override
  void onWindowLeaveFullScreen() => _signal.value = false;
}
