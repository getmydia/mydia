import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../native/lib.dart' show FlutterPlaybackState;
import '../remote/remote_control_intent.dart';
import '../remote/remote_target_controller.dart';

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

/// Turns menu and Dock commands from the host into app actions.
///
/// Playback commands go through [RemoteTargetController], the same seam a
/// remote control uses, so the Dock needs no player callbacks of its own and
/// inherits its handling of "no player attached".
class AppMenuCommands {
  AppMenuCommands({
    required void Function(String route) go,
    required void Function() back,
    required RemoteTargetController remote,
  })  : _go = go,
        _back = back,
        _remote = remote;

  final void Function(String route) _go;
  final void Function() _back;
  final RemoteTargetController _remote;

  void attach({MethodChannel channel = kAppMenuChannel}) =>
      channel.setMethodCallHandler(handle);

  void detach({MethodChannel channel = kAppMenuChannel}) =>
      channel.setMethodCallHandler(null);

  @visibleForTesting
  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'navigate':
        final route = call.arguments;
        if (route is String && route.startsWith('/')) {
          _go(route);
        } else {
          debugPrint('[AppMenu] Ignoring navigate to $route');
        }
      case 'back':
        _back();
      case 'togglePlayPause':
        final snapshot = _remote.snapshot();
        if (snapshot == null) return null;
        _remote.submit(TransportIntent(
          snapshot.state == FlutterPlaybackState.playing
              ? TransportAction.pause
              : TransportAction.play,
        ));
      case 'nextEpisode':
        _remote.submit(const EpisodeStepIntent(EpisodeStep.next));
      default:
        throw MissingPluginException('AppMenu: no handler for ${call.method}');
    }
    return null;
  }
}
