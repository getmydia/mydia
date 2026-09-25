/// GTK window frame state, read over a platform channel.
///
/// Conditional import so the web build never links a `MethodChannel` call
/// that could never succeed there. Mirrors `decoration_layout_source.dart`.
library;

export 'window_frame_state_source_stub.dart'
    if (dart.library.io) 'window_frame_state_source_native.dart';
