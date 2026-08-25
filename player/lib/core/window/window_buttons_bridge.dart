/// Hides/shows the window's close/minimize/maximize buttons to match the
/// playback controls' own visibility.
///
/// Conditional import so the web build never links a `MethodChannel` call
/// that could never succeed there. Mirrors `desktop_window.dart`.
///
/// `dart.library.io` is also true on iOS and Android, so
/// [shouldCallNativeButtonBridge] additionally gates on the target platform.
library;

export 'window_buttons_bridge_stub.dart'
    if (dart.library.io) 'window_buttons_bridge_native.dart';
