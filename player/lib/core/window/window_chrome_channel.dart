/// The platform channel name shared by the window buttons bridge and the
/// GTK decoration layout source, so the two Dart-side `MethodChannel`
/// declarations can never drift from each other.
///
/// Matched literally on the native side by
/// `linux/runner/my_application.cc` (`kWindowChromeChannel`) and
/// `macos/Runner/AppDelegate.swift`. Changing this string requires updating
/// both.
///
/// Deliberately just the name, not a shared `MethodChannel` instance: the
/// two Dart sides open separate channel objects with separate handlers.
const String kWindowChromeChannelName = 'dev.mydia.player/window_chrome';
