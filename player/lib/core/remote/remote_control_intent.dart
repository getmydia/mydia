import 'package:flutter/foundation.dart' show immutable;

import '../../native/lib.dart';

enum TransportAction { play, pause, stop, seek }

enum TrackKind { audio, subtitle }

enum EpisodeStep { next, previous }

/// Something a controller asked this device to do.
///
/// Deliberately free of any playback or widget dependency. The receiver builds
/// these and an app-level listener carries them out, which is what keeps the
/// p2p layer and the player screen from importing each other.
@immutable
sealed class RemoteControlIntent {
  const RemoteControlIntent();

  /// Translates a wire command into an intent, or null when the command is not
  /// a playback action. `Hello` and `GetState` are answered by the receiver
  /// itself and never reach the player.
  static RemoteControlIntent? fromRequest(FlutterRemoteControlRequest request) {
    return switch (request) {
      FlutterRemoteControlRequest_Play() =>
        const TransportIntent(TransportAction.play),
      FlutterRemoteControlRequest_Pause() =>
        const TransportIntent(TransportAction.pause),
      FlutterRemoteControlRequest_Stop() =>
        const TransportIntent(TransportAction.stop),
      FlutterRemoteControlRequest_Seek(:final positionMs) => TransportIntent(
          TransportAction.seek,
          position: Duration(milliseconds: positionMs.toInt()),
        ),
      FlutterRemoteControlRequest_SetVolume(:final level) =>
        VolumeIntent(level: level),
      FlutterRemoteControlRequest_SetMute(:final muted) =>
        VolumeIntent(muted: muted),
      FlutterRemoteControlRequest_SelectAudioTrack(:final id) =>
        TrackSelectionIntent(kind: TrackKind.audio, trackId: id),
      FlutterRemoteControlRequest_SelectSubtitleTrack(:final id) =>
        TrackSelectionIntent(kind: TrackKind.subtitle, trackId: id),
      FlutterRemoteControlRequest_NextEpisode() =>
        const EpisodeStepIntent(EpisodeStep.next),
      FlutterRemoteControlRequest_PreviousEpisode() =>
        const EpisodeStepIntent(EpisodeStep.previous),
      FlutterRemoteControlRequest_LoadContent(:final field0) =>
        LoadContentIntent(
          mediaItemId: field0.mediaItemId,
          episodeId: field0.episodeId,
          startAt: Duration(milliseconds: field0.positionMs.toInt()),
          audioTrack: field0.audioTrack,
          subtitleTrack: field0.subtitleTrack,
          autoplay: field0.autoplay,
        ),
      FlutterRemoteControlRequest_Hello() => null,
      FlutterRemoteControlRequest_GetState() => null,
    };
  }
}

@immutable
class TransportIntent extends RemoteControlIntent {
  final TransportAction action;

  /// Set only for [TransportAction.seek].
  final Duration? position;

  const TransportIntent(this.action, {this.position});
}

@immutable
class TrackSelectionIntent extends RemoteControlIntent {
  final TrackKind kind;

  /// Null means clear the track, which is meaningful for subtitles.
  final String? trackId;

  const TrackSelectionIntent({required this.kind, this.trackId});
}

@immutable
class VolumeIntent extends RemoteControlIntent {
  /// 0.0 to 1.0, or null when only mute changed.
  final double? level;
  final bool? muted;

  const VolumeIntent({this.level, this.muted});
}

@immutable
class EpisodeStepIntent extends RemoteControlIntent {
  final EpisodeStep step;

  const EpisodeStepIntent(this.step);
}

/// Play this item. A reference, never a URL: the target resolves its own
/// stream against the server it is already paired to.
@immutable
class LoadContentIntent extends RemoteControlIntent {
  final String mediaItemId;
  final String? episodeId;
  final Duration startAt;
  final String? audioTrack;
  final String? subtitleTrack;
  final bool autoplay;

  const LoadContentIntent({
    required this.mediaItemId,
    required this.episodeId,
    required this.startAt,
    required this.audioTrack,
    required this.subtitleTrack,
    required this.autoplay,
  });
}
