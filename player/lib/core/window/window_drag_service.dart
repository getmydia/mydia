// Cross-platform OS window dragging.
//
// Uses conditional imports so the web build never links `window_manager`,
// which has no web implementation. Mirrors `network_info_service.dart` in
// this same directory.
export 'window_drag_service_stub.dart'
    if (dart.library.io) 'window_drag_service_native.dart';
