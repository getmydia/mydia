/// Picks the platform backend.
///
/// Mirrors `core/window/desktop_window.dart`: the default target is the one
/// that must not link platform-only packages, and the conditional target is
/// the specialised one. Here the web build is the specialised case, since
/// `package:web` has no native implementation.
export 'fullscreen_backend_native.dart'
    if (dart.library.js_interop) 'fullscreen_backend_web.dart';
