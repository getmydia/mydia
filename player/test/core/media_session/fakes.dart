import 'dart:async';

import 'package:player/core/media_session/media_session_state.dart';
import 'package:player/core/media_session/system_media_session.dart';
import 'package:player/core/remote/remote_control_intent.dart';
import 'package:player/core/remote/remote_target_controller.dart';
import 'package:player/native/lib.dart';

FlutterPlaybackSnapshot buildSnapshot({
  FlutterPlaybackState state = FlutterPlaybackState.playing,
  String? mediaItemId = 'item-1',
  String? episodeId,
  String title = 'The Glass Orchard',
  Duration position = const Duration(seconds: 10),
  Duration duration = const Duration(minutes: 90),
  double? volume = 0.8,
  bool muted = false,
  bool nextPrevious = false,
  int sequence = 1,
}) =>
    FlutterPlaybackSnapshot(
      state: state,
      mediaItemId: mediaItemId,
      episodeId: episodeId,
      title: title,
      subtitle: null,
      imageUrl: null,
      positionMs: BigInt.from(position.inMilliseconds),
      durationMs: BigInt.from(duration.inMilliseconds),
      volume: volume,
      muted: muted,
      audioTracks: const [],
      subtitleTracks: const [],
      selectedAudio: null,
      selectedSubtitle: null,
      capabilities: FlutterTargetCapabilities(
        volume: true,
        trackSelection: true,
        nextPrevious: nextPrevious,
      ),
      sequence: BigInt.from(sequence),
    );

/// A binding whose snapshot the test sets directly.
class FakeBinding implements RemotePlayerBinding {
  FakeBinding(this.current);

  FlutterPlaybackSnapshot current;
  final calls = <String>[];

  @override
  FlutterPlaybackSnapshot describe(int sequence) => current;

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seek(Duration to) async => calls.add('seek:${to.inSeconds}');
  @override
  Future<void> setVolume(double level) async => calls.add('volume:$level');
  @override
  Future<void> setMuted(bool muted) async => calls.add('muted:$muted');
  @override
  Future<void> selectTrack(TrackKind kind, String? id) async =>
      calls.add('track:${kind.name}:$id');
  @override
  Future<void> stepEpisode(EpisodeStep step) async =>
      calls.add('episode:${step.name}');
}

/// Records every state pushed to it; the test injects OS commands.
class FakeMediaSession implements SystemMediaSession {
  final updates = <MediaSessionState>[];
  final commandsIn = StreamController<RemoteControlIntent>.broadcast();
  final raiseIn = StreamController<void>.broadcast();
  bool disposed = false;
  bool throwOnUpdate = false;

  @override
  Stream<RemoteControlIntent> get commands => commandsIn.stream;
  @override
  Stream<void> get raiseRequests => raiseIn.stream;

  @override
  Future<void> update(MediaSessionState state) async {
    if (throwOnUpdate) throw StateError('bus gone');
    updates.add(state);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await commandsIn.close();
    await raiseIn.close();
  }
}
