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
}) {
  if (hasRealTracks(current)) return Future.value(true);

  final completer = Completer<bool>();
  late final StreamSubscription<Tracks> subscription;
  late final Timer timer;

  // Every outcome (a matching event, the stream closing, the cap) cancels
  // both the subscription and the timer, so neither outlives this call --
  // an earlier version left `firstWhere`'s subscription on `updates` alive
  // after a timeout.
  void finish(bool result) {
    if (completer.isCompleted) return;
    completer.complete(result);
    subscription.cancel();
    timer.cancel();
  }

  subscription = updates.listen(
    (tracks) {
      if (hasRealTracks(tracks)) finish(true);
    },
    onDone: () => finish(false), // The stream closed first.
  );
  timer = Timer(timeout, () => finish(false));

  return completer.future;
}
