import 'package:flutter/foundation.dart';

import '../../native/lib.dart';

/// The three states every OS media session understands.
enum MediaSessionStatus { playing, paused, stopped }

/// What the server knows about the item beyond the snapshot: a nicer title
/// for episodes, a second line, and the poster.
@immutable
class NowPlayingMetadata {
  const NowPlayingMetadata({this.title, this.subtitle, this.posterUrl});

  final String? title;
  final String? subtitle;
  final String? posterUrl;

  @override
  bool operator ==(Object other) =>
      other is NowPlayingMetadata &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.posterUrl == posterUrl;

  @override
  int get hashCode => Object.hash(title, subtitle, posterUrl);
}

/// Platform-neutral description of what the OS should show.
@immutable
class MediaSessionState {
  const MediaSessionState({
    required this.status,
    required this.title,
    this.trackId,
    this.subtitle,
    this.artworkPath,
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.volume = 1.0,
    this.canSeek = false,
    this.canGoNext = false,
    this.canGoPrevious = false,
    this.buffering = false,
  });

  static const stopped =
      MediaSessionState(status: MediaSessionStatus.stopped, title: '');

  final MediaSessionStatus status;

  /// Episode id for an episode, media item id for a movie.
  final String? trackId;
  final String title;
  final String? subtitle;

  /// Absolute path of a locally cached poster, readable by the OS shell.
  final String? artworkPath;
  final Duration duration;
  final Duration position;

  /// 0.0 to 1.0.
  final double volume;
  final bool canSeek;
  final bool canGoNext;
  final bool canGoPrevious;

  /// Set while the player is rebuffering. Status stays [MediaSessionStatus.playing]
  /// (MPRIS has no separate buffering status), but this stops [MprisMediaSession]
  /// from treating the stall's wall-clock time as elapsed playback.
  final bool buffering;

  @override
  bool operator ==(Object other) =>
      other is MediaSessionState &&
      other.status == status &&
      other.trackId == trackId &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.artworkPath == artworkPath &&
      other.duration == duration &&
      other.position == position &&
      other.volume == volume &&
      other.canSeek == canSeek &&
      other.canGoNext == canGoNext &&
      other.canGoPrevious == canGoPrevious &&
      other.buffering == buffering;

  @override
  int get hashCode => Object.hash(status, trackId, title, subtitle, artworkPath,
      duration, position, volume, canSeek, canGoNext, canGoPrevious, buffering);

  @override
  String toString() =>
      'MediaSessionState($status, $trackId, "$title", $position/$duration)';
}

MediaSessionStatus _statusOf(FlutterPlaybackState state) => switch (state) {
      FlutterPlaybackState.playing ||
      FlutterPlaybackState.buffering =>
        MediaSessionStatus.playing,
      FlutterPlaybackState.paused ||
      FlutterPlaybackState.loading =>
        MediaSessionStatus.paused,
      FlutterPlaybackState.idle ||
      FlutterPlaybackState.ended ||
      FlutterPlaybackState.error =>
        MediaSessionStatus.stopped,
    };

/// Maps what the attached player reports, plus resolved metadata, onto a
/// session state. A null [snapshot] means no player is on screen.
MediaSessionState mediaSessionStateFrom(
  FlutterPlaybackSnapshot? snapshot, {
  NowPlayingMetadata? metadata,
  String? artworkPath,
}) {
  if (snapshot == null) return MediaSessionState.stopped;
  final duration = Duration(milliseconds: snapshot.durationMs.toInt());
  final status = _statusOf(snapshot.state);
  final nextPrevious = snapshot.capabilities.nextPrevious;
  return MediaSessionState(
    status: status,
    trackId: snapshot.episodeId ?? snapshot.mediaItemId,
    title: metadata?.title ?? snapshot.title,
    subtitle: metadata?.subtitle,
    artworkPath: artworkPath,
    duration: duration,
    position: Duration(milliseconds: snapshot.positionMs.toInt()),
    volume: snapshot.muted ? 0.0 : (snapshot.volume ?? 1.0),
    canSeek: duration > Duration.zero && status != MediaSessionStatus.stopped,
    canGoNext: nextPrevious,
    canGoPrevious: nextPrevious,
    buffering: snapshot.state == FlutterPlaybackState.buffering,
  );
}
