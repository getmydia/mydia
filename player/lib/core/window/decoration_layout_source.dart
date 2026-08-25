/// GTK window button layout, read over a platform channel.
///
/// Conditional import so the web build never links a `MethodChannel` call
/// that could never succeed there. Mirrors `window_buttons_bridge.dart` and
/// `desktop_window.dart`.
library;

export 'decoration_layout_source_stub.dart'
    if (dart.library.io) 'decoration_layout_source_native.dart';
