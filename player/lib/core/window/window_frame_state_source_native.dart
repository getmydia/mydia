/// Reads the Linux window's frame state over the platform channel and keeps
/// it current.
///
/// Nothing here throws, for the startup reason
/// `decoration_layout_source_native.dart` records. Platforms other than
/// Linux answer `MissingPluginException`, which is caught and leaves the
/// floating state in place; `DesktopWindowChrome` only reads this on Linux
/// anyway.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'window_chrome_channel.dart';
import 'window_frame_state.dart';

const MethodChannel _channel = MethodChannel(kWindowFrameChannelName);

class WindowFrameStateSource {
  WindowFrameStateSource() {
    _channel.setMethodCallHandler(_onCall);
  }

  final ValueNotifier<WindowFrameState> _state =
      ValueNotifier<WindowFrameState>(WindowFrameState.floating);

  /// The current state. Starts floating so callers can read it before [load]
  /// has been awaited.
  ValueListenable<WindowFrameState> get state => _state;

  /// Bumped by every read and every push, so a slow startup read cannot
  /// overwrite a newer pushed state. Same race and remedy as
  /// `DecorationLayoutSource._revision`.
  int _revision = 0;

  /// Reads the state once. Safe to call on any platform.
  Future<void> load() async {
    final revision = ++_revision;
    try {
      final raw = await _channel.invokeMethod<Object?>('getWindowState');
      if (revision == _revision) {
        _state.value = WindowFrameState.fromChannel(raw);
      }
    } catch (e) {
      debugPrint('[WindowFrameState] Failed to read the window state: $e');
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'onWindowStateChanged') {
      _revision++;
      _state.value = WindowFrameState.fromChannel(call.arguments);
    }
    return null;
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _state.dispose();
  }
}
