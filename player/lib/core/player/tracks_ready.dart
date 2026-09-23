import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// media_kit lists `auto` and `no` in every track list before anything is
/// probed, so a non-empty list says nothing. A real track has any other id.
bool hasRealTracks(Tracks tracks) =>
    tracks.video.any((t) => _isReal(t.id)) ||
    tracks.audio.any((t) => _isReal(t.id));

bool _isReal(String id) => id != 'auto' && id != 'no';

/// Waits until mpv has probed the opened media, or [timeout] passes.
///
/// Replaces a fixed 500 ms sleep after `player.open` that every playback paid
/// whether mpv needed it or not. Returns false on timeout, and the caller
/// carries on exactly as it did after the sleep.
Future<bool> awaitRealTracks({
  required Tracks current,
  required Stream<Tracks> updates,
  Duration timeout = const Duration(seconds: 3),
}) async {
  if (hasRealTracks(current)) return true;
  try {
    await updates.firstWhere(hasRealTracks).timeout(timeout);
    return true;
  } on TimeoutException {
    return false;
  } on StateError {
    return false; // The stream closed first.
  }
}
