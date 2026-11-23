import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'mac_window_channel.dart';
import 'window_event_listener.dart';

/// The app's one OS window, from nativeapi (window_manager 0.7's native API),
/// and the fan-out of its events to [WindowEventListener]s.
///
/// The window is found lazily with `WindowManager.instance.getCurrent()` and
/// kept once found. Until then every call looks again: on Windows the current
/// window is the active one, and before the first frame the runner has not
/// shown it yet, though `GetCurrent` then falls back to this process's first
/// top-level window, hidden or not. Listeners added before the window is
/// found are wired to it when it is.
///
/// nativeapi reports one `WindowRestoredEvent` for leaving both the maximized
/// and the minimized state, so [onWindowUnmaximize] is told apart from what
/// came before, as window_manager's own 0.5.x bridge does.
///
/// macOS is the exception to all of the above. Dart runs off the main thread
/// there (`docs/playback.md`, "macOS keeps Dart off the main thread"), and
/// nativeapi cannot find the window from that thread. After
/// [attachMacChannel], events come from `macos/Runner/WindowPlugin.swift`
/// through [handleMacEvent] instead, no nativeapi window is ever looked up,
/// and the same bookkeeping and fan-out apply.
class NativeWindowHost {
  NativeWindowHost._();

  /// A host with no window, for driving [handleEvent] in tests.
  @visibleForTesting
  NativeWindowHost.detached();

  static final NativeWindowHost instance = NativeWindowHost._();

  Window? _window;
  ListenerId? _nativeListener;
  final List<WindowEventListener> _listeners = [];

  bool _maximized = false;
  bool _minimized = false;
  bool _fullScreen = false;

  /// Set by [attachMacChannel]: events come from the channel and [window]
  /// stays null.
  bool _macChannel = false;

  /// The window, or null when none can be found yet. Throws when the native
  /// library is not loaded (a bare `flutter test` VM); callers guard that.
  Window? get window {
    if (_macChannel) return null;
    final known = _window;
    if (known != null) return known;
    final found = WindowManager.instance.getCurrent();
    if (found != null) {
      _window = found;
      if (_listeners.isNotEmpty) _wire(found);
    }
    return found;
  }

  /// [window], or a [StateError] when there is none yet.
  Window requireWindow() =>
      window ?? (throw StateError('No native window found yet'));

  /// Never throws: with no native library the listener is kept and wired
  /// once a window is found.
  void addListener(WindowEventListener listener) {
    if (!_listeners.contains(listener)) _listeners.add(listener);
    if (_macChannel) return;
    try {
      final found = window;
      if (found != null) _wire(found);
    } catch (e) {
      debugPrint('[NativeWindowHost] Failed to wire window events: $e');
    }
  }

  void removeListener(WindowEventListener listener) {
    _listeners.remove(listener);
  }

  /// Switches to macOS mode: events from [channel], state seeded from the
  /// window's current [fullScreen] and [maximized], read by the caller
  /// through the channel. Call before the first [addListener].
  void attachMacChannel(
    MacWindowChannel channel, {
    required bool fullScreen,
    required bool maximized,
  }) {
    _macChannel = true;
    _fullScreen = fullScreen;
    _maximized = maximized;
    channel.listen(handleMacEvent);
  }

  /// Translates one `WindowPlugin` event into [WindowEventListener] calls.
  /// Unknown events are ignored, so a newer Runner cannot break an older
  /// build's Dart.
  @visibleForTesting
  void handleMacEvent(String event, Map<Object?, Object?>? args) {
    switch (event) {
      case 'closeRequested':
        _emit((l) => l.onWindowClose());
      case 'enteredFullScreen':
        _setFullScreen(true);
      case 'exitedFullScreen':
        _setFullScreen(false);
      case 'maximized':
        _onMaximized();
      case 'unmaximized':
        // WindowPlugin sends this only for a zoom ending, so the window
        // is on screen and no longer maximized.
        _restored(maximizedNow: false);
      case 'minimized':
        _minimized = true;
      case 'restored':
        // Back from the Dock. Only bookkeeping: leaving minimized is no
        // unmaximize, whatever state it lands in.
        _minimized = false;
        _maximized = args?['maximized'] == true;
      case 'resized':
        _emit((l) => l.onWindowResize());
      case 'moved':
        _emit((l) => l.onWindowMove());
      default:
        break;
    }
  }

  void _wire(Window window) {
    if (_nativeListener != null) return;
    // State may have changed before anyone listened. A restored event alone
    // cannot say which state it left.
    _maximized = window.isMaximized;
    _minimized = window.isMinimized;
    _fullScreen = window.isFullScreen;
    _nativeListener = window.addListener(handleEvent);
  }

  /// Translates one nativeapi event into [WindowEventListener] calls.
  @visibleForTesting
  void handleEvent(WindowEvent event) {
    switch (event) {
      case WindowCloseRequestedEvent():
        _emit((l) => l.onWindowClose());
      case WindowEnteredFullScreenEvent():
        _setFullScreen(true);
      case WindowExitedFullScreenEvent():
        _setFullScreen(false);
      case WindowMaximizedEvent():
        _onMaximized();
      case WindowMinimizedEvent():
        _minimized = true;
      case WindowRestoredEvent():
        // Leaving the minimized state may land back in the maximized one.
        _restored(maximizedNow: _window?.isMaximized ?? false);
      case WindowResizedEvent():
        _emit((l) => l.onWindowResize());
      case WindowMovedEvent():
        _emit((l) => l.onWindowMove());
      default:
        break;
    }
  }

  void _onMaximized() {
    // A minimized window that was maximized comes back with this alone.
    _minimized = false;
    _maximized = true;
    _emit((l) => l.onWindowMaximize());
  }

  /// Leaves the minimized or maximized state for one where the window is
  /// [maximizedNow]. Only leaving maximized for an on-screen, unmaximized
  /// window is an unmaximize.
  void _restored({required bool maximizedNow}) {
    final wasMinimized = _minimized;
    final wasMaximized = _maximized;
    _minimized = false;
    _maximized = maximizedNow;
    if (!wasMinimized && wasMaximized && !_maximized) {
      _emit((l) => l.onWindowUnmaximize());
    }
  }

  void _setFullScreen(bool value) {
    if (value == _fullScreen) return;
    _fullScreen = value;
    _emit(
      (l) => value ? l.onWindowEnterFullScreen() : l.onWindowLeaveFullScreen(),
    );
  }

  /// A snapshot, so a listener that removes itself (the sizer's detach) or
  /// adds another does not disturb this round.
  void _emit(void Function(WindowEventListener) call) {
    for (final listener in List.of(_listeners)) {
      if (!_listeners.contains(listener)) continue;
      try {
        call(listener);
      } catch (e, st) {
        debugPrint('[NativeWindowHost] Window listener threw: $e\n$st');
      }
    }
  }
}
