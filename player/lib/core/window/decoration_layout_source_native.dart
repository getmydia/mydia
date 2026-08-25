/// Reads GTK's window button layout over the platform channel and keeps it
/// current.
///
/// Nothing here is allowed to throw. It runs during app startup, whose stated
/// invariant is that nothing after `WidgetsFlutterBinding.ensureInitialized()`
/// escapes uncaught, and a failure only costs the fallback layout. Mirrors
/// `window_buttons_bridge_native.dart`.
///
/// `dart.library.io` is also true on iOS, Android, macOS and Windows, where
/// `getDecorationLayout` is not implemented. Those platforms get a
/// `MissingPluginException`, which is caught here and leaves the fallback in
/// place, so no extra platform gate is needed.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'decoration_layout.dart';
import 'window_chrome_channel.dart';

const MethodChannel _channel = MethodChannel(kWindowChromeChannelName);

class DecorationLayoutSource {
  DecorationLayoutSource() {
    _channel.setMethodCallHandler(_onCall);
  }

  final ValueNotifier<DecorationLayout> _layout =
      ValueNotifier<DecorationLayout>(
    parseDecorationLayout(kFallbackDecorationLayout),
  );

  /// The current layout. Starts on the fallback and never becomes null, so
  /// callers can read it before [load] has been awaited.
  ValueListenable<DecorationLayout> get layout => _layout;

  /// Reads the layout once. Safe to call on any platform.
  Future<void> load() async {
    try {
      final raw = await _channel.invokeMethod<String>('getDecorationLayout');
      _publish(raw ?? '');
    } catch (e) {
      debugPrint('[DecorationLayout] Failed to read the layout: $e');
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'onDecorationLayoutChanged') {
      _publish(call.arguments as String? ?? '');
    }
    return null;
  }

  /// `ValueNotifier` already suppresses a write of an equal value, and
  /// `DecorationLayout` has value equality, so two different strings that
  /// parse the same (`appmenu:close` and `icon:close`) do not rebuild the
  /// chrome.
  void _publish(String raw) => _layout.value = parseDecorationLayout(raw);

  void dispose() {
    _channel.setMethodCallHandler(null);
    _layout.dispose();
  }
}
