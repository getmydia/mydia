import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:media_kit/media_kit.dart';

import '../../../domain/models/audio_track.dart' as app_models_audio;

/// media_kit's current audio track list mapped onto the app's own model,
/// together with the reverse lookup needed to hand a chosen track back to
/// media_kit.
@visibleForTesting
class AudioTrackDetection {
  const AudioTrackDetection({required this.tracks, required this.byId});

  /// Selectable tracks, in the order media_kit reports them. Never contains
  /// the `auto`/`no` sentinels.
  final List<app_models_audio.AudioTrack> tracks;

  /// [app_models_audio.AudioTrack.id] to the media_kit track it came from.
  /// `_showAudioSelector` passes the resolved value to `setAudioTrack`, so a
  /// missing entry silently no-ops the user's choice.
  final Map<String, AudioTrack> byId;
}

/// Maps media_kit's audio tracks onto the app's model.
///
/// Extracted as a free function so the mapping can be unit-tested without a
/// live `Player` — see `shouldRestartForSeek`'s dartdoc for why one cannot be
/// constructed under `flutter test`.
///
/// Which track counts as the default comes from media_kit's own `isDefault`
/// flag, which carries the container's disposition. Position is only the
/// fallback, for files that flag nothing: a dual-language release can order
/// its tracks one way and flag another, and picking by position alone
/// mislabels those.
AudioTrackDetection detectAudioTracks(List<AudioTrack> mkTracks) {
  final tracks = <app_models_audio.AudioTrack>[];
  final byId = <String, AudioTrack>{};

  for (final mkTrack in mkTracks) {
    // Skip the "auto" and "no" sentinel tracks
    if (mkTrack == AudioTrack.auto() || mkTrack == AudioTrack.no()) continue;

    tracks.add(
      app_models_audio.AudioTrack(
        id: mkTrack.id,
        language: mkTrack.language ?? 'und',
        title: mkTrack.title,
        isDefault: mkTrack.isDefault ?? false,
      ),
    );
    byId[mkTrack.id] = mkTrack;
  }

  if (tracks.isNotEmpty && !tracks.any((t) => t.isDefault)) {
    final first = tracks.first;
    tracks[0] = app_models_audio.AudioTrack(
      id: first.id,
      language: first.language,
      title: first.title,
      isDefault: true,
    );
  }

  return AudioTrackDetection(tracks: tracks, byId: byId);
}

/// Reports media_kit's track list every time it is revised.
///
/// mpv discovers tracks asynchronously while it probes the file, and revises
/// the list afterwards, so sampling it once at a fixed moment after `open()`
/// races the probe. On a slow enough source the sample lands before any
/// track exists and the selectors are left permanently empty. Driving
/// detection off the stream instead means a late arrival still reaches the
/// UI.
///
/// `player.stream.tracks` is a plain broadcast stream with no replay, so
/// callers must subscribe before opening the media and still run a detection
/// pass afterwards to cover anything emitted in between.
StreamSubscription<Tracks> watchTracks(
  Stream<Tracks> tracks,
  void Function(Tracks tracks) onTracks,
) {
  return tracks.listen(onTracks);
}
