/// Hides/shows the macOS traffic-light window buttons (close/minimize/zoom)
/// to match the playback controls' own visibility.
///
/// Conditional import so the web build never links a `MethodChannel` call
/// that could never succeed there. Mirrors `desktop_window.dart`.
///
/// `dart.library.io` is also true on iOS and Android, so
/// [shouldControlTrafficLights] additionally gates on the target platform
/// being macOS.
library;

export 'traffic_lights_stub.dart'
    if (dart.library.io) 'traffic_lights_native.dart';
