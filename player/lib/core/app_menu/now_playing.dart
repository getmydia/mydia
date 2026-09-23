import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_menu_channel.dart';

/// What the Dock menu shows about current playback.
@immutable
class NowPlaying {
  const NowPlaying({
    required this.title,
    required this.isPlaying,
    required this.hasNext,
  });

  final String title;
  final bool isPlaying;
  final bool hasNext;

  Map<String, Object> toWire() => {
        'title': title,
        'isPlaying': isPlaying,
        'hasNext': hasNext,
      };

  @override
  bool operator ==(Object other) =>
      other is NowPlaying &&
      other.title == title &&
      other.isPlaying == isPlaying &&
      other.hasNext == hasNext;

  @override
  int get hashCode => Object.hash(title, isPlaying, hasNext);
}

/// Sends [state] to the Swift side, or clears it when null.
///
/// Never throws: this runs from playback listeners, and playback must never
/// fail because of the Dock.
Future<void> sendNowPlaying(
  NowPlaying? state, {
  MethodChannel channel = kAppMenuChannel,
}) async {
  try {
    if (state == null) {
      await channel.invokeMethod<void>('clearNowPlaying');
    } else {
      await channel.invokeMethod<void>('setNowPlaying', state.toWire());
    }
  } on PlatformException catch (e) {
    debugPrint('[AppMenu] Now Playing update failed: $e');
  } on MissingPluginException catch (e) {
    debugPrint('[AppMenu] Now Playing host unavailable: $e');
  }
}

/// Holds the one player allowed to report Now Playing, and forwards its
/// reports to the host.
///
/// Ownership mirrors `RemoteTargetController.detachPlayer`: Flutter mounts a
/// new `PlayerScreen` before it disposes the old one, so the old screen's
/// late [clear] (or a last `playing` event during its teardown) must not
/// overwrite what the new screen reported. Only the latest [claim]ant may
/// [publish] or [clear].
class NowPlayingPublisher {
  NowPlayingPublisher(this._send);

  final Future<void> Function(NowPlaying?) _send;
  Object? _owner;
  NowPlaying? _current;

  /// The last state sent, or null when nothing is playing.
  NowPlaying? get current => _current;

  /// Takes over from any previous owner. A state the previous owner left
  /// live is cleared, so a new screen that fails before its first report
  /// never leaves the old screen's controls in the Dock.
  void claim(Object owner) {
    _owner = owner;
    if (_current == null) return;
    _current = null;
    unawaited(_send(null));
  }

  void publish(Object owner, NowPlaying state) {
    if (!identical(_owner, owner) || state == _current) return;
    _current = state;
    unawaited(_send(state));
  }

  void clear(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _current = null;
    unawaited(_send(null));
  }
}

/// One publisher for the app's lifetime. Off macOS it records state (which
/// tests read through [NowPlayingPublisher.current]) but sends nothing.
final nowPlayingPublisherProvider = Provider<NowPlayingPublisher>(
  (ref) => NowPlayingPublisher(
    appMenuSupported ? sendNowPlaying : (_) async {},
  ),
);
