import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The channel between Dart and `macos/Runner/AppMenu.swift`, which owns the
/// menu bar and the Dock menu.
///
/// Swift to Dart:
/// - `navigate(route)`: a Go, Settings or Dock shortcut item was chosen.
/// - `back`: Go > Back.
/// - `togglePlayPause`, `nextEpisode`: Dock menu playback controls.
///
/// Dart to Swift:
/// - `setNowPlaying({title, isPlaying, hasNext})`: what the Dock menu shows.
/// - `clearNowPlaying`: nothing is playing.
///
/// Dart pushes the Now Playing state rather than Swift asking for it because
/// `applicationDockMenu` is synchronous and cannot wait on Dart, the same
/// constraint `UpdaterDelegate` in `AppDelegate.swift` documents for the
/// release track. The name is matched literally in `AppMenu.swift`.
const MethodChannel kAppMenuChannel =
    MethodChannel('dev.mydia.player/app_menu');

/// Whether this build has a native app menu to talk to.
bool get appMenuSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
