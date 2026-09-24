// Conditional import so the web build never links package:dbus or dart:io.
// Mirrors lib/core/window/desktop_window.dart.
export 'platform_media_session_stub.dart'
    if (dart.library.io) 'platform_media_session_native.dart';
