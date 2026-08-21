import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../native/lib.dart';
import 'remote_control_intent.dart';

/// What a mounted player exposes to a remote controller.
///
/// Implemented by `PlayerScreen`. Declared here rather than there so
/// `core/remote/` never imports `presentation/`, which is what keeps the
/// receiver unit-testable and the two layers free of a cycle.
abstract class RemotePlayerBinding {
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration to);
  Future<void> setVolume(double level);
  Future<void> setMuted(bool muted);
  Future<void> selectTrack(TrackKind kind, String? id);
  Future<void> stepEpisode(EpisodeStep step);

  /// Current state, stamped with the sequence number the caller supplies.
  FlutterPlaybackSnapshot describe(int sequence);
}

/// The seam between inbound control and real playback.
///
/// Transport intents go straight to whatever player is mounted. `LoadContent`
/// goes out on [intents] instead, because it has to work when nothing is
/// mounted at all: the app layer listens and navigates.
class RemoteTargetController {
  RemotePlayerBinding? _binding;
  int _sequence = 0;

  final _intents = StreamController<RemoteControlIntent>.broadcast();

  /// Intents the app layer must handle. Today that is `LoadContent` only.
  Stream<RemoteControlIntent> get intents => _intents.stream;

  void attachPlayer(RemotePlayerBinding binding) => _binding = binding;

  /// Detaches [binding] — or, if none is given, whatever is currently
  /// attached (for callers with nothing to identify themselves by).
  ///
  /// Ignores a detach from a binding that has already been replaced. Flutter
  /// mounts a new `PlayerScreen` before it disposes the old one: a remote
  /// `LoadContent` that pushes a second screen over an existing one runs
  /// `attachPlayer(new)` first, then `detachPlayer()` from the *old* screen's
  /// `dispose` some time later. Without the ownership check, that late
  /// detach would null out the newer, live binding — every later transport
  /// command would then be silently dropped and `snapshot()` would report
  /// "not playing" while a player is actually on screen.
  void detachPlayer([RemotePlayerBinding? binding]) {
    if (binding != null && !identical(_binding, binding)) return;
    _binding = null;
  }

  /// Current playback state, or null when no player is mounted.
  ///
  /// The sequence advances on every call so two controllers polling at once
  /// can discard a snapshot that arrived out of order.
  FlutterPlaybackSnapshot? snapshot() {
    final binding = _binding;
    if (binding == null) return null;
    _sequence += 1;
    return binding.describe(_sequence);
  }

  void submit(RemoteControlIntent intent) {
    if (intent is LoadContentIntent) {
      _intents.add(intent);
      return;
    }

    final binding = _binding;
    if (binding == null) {
      // The receiver already answers NotPlaying for this case; reaching here
      // means the player detached between the check and the dispatch, which is
      // a race rather than a bug worth surfacing.
      debugPrint('[RemoteControl] dropping $intent, no player attached');
      return;
    }

    unawaited(_dispatch(binding, intent));
  }

  Future<void> _dispatch(
      RemotePlayerBinding binding, RemoteControlIntent intent) async {
    try {
      switch (intent) {
        case TransportIntent(:final action, :final position):
          switch (action) {
            case TransportAction.play:
              await binding.play();
            case TransportAction.pause:
              await binding.pause();
            case TransportAction.stop:
              await binding.stop();
            case TransportAction.seek:
              if (position != null) await binding.seek(position);
          }
        case VolumeIntent(:final level, :final muted):
          if (level != null) await binding.setVolume(level);
          if (muted != null) await binding.setMuted(muted);
        case TrackSelectionIntent(:final kind, :final trackId):
          await binding.selectTrack(kind, trackId);
        case EpisodeStepIntent(:final step):
          await binding.stepEpisode(step);
        case LoadContentIntent():
          // Handled above, before dispatch.
          break;
      }
    } catch (error) {
      debugPrint('[RemoteControl] dispatch failed: $error');
    }
  }

  void dispose() => _intents.close();
}

/// One controller for the app's lifetime. `app.dart` subscribes to
/// [RemoteTargetController.intents] once at startup; whichever `PlayerScreen`
/// is on screen attaches and detaches itself as it mounts and unmounts.
final remoteTargetControllerProvider = Provider<RemoteTargetController>((ref) {
  final controller = RemoteTargetController();
  ref.onDispose(controller.dispose);
  return controller;
});
