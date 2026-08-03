// Cross-platform desktop window management: geometry persistence, OS window
// dragging, and player aspect sizing.
//
// Conditional imports so the web build never links `window_manager` or
// `screen_retriever`, neither of which has a web implementation. Mirrors
// `network_info_service.dart`.
//
// `dart.library.io` is also true on iOS and Android, so the native side gates
// every entry point on `PlatformFeatures.isDesktop` as well.
export 'desktop_window_stub.dart'
    if (dart.library.io) 'desktop_window_native.dart';
