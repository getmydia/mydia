/// Progress for servers that take a position report and a watched mark as
/// separate calls: Plex's timeline and scrobble, Stash's activity and play
/// count. Reports every ten seconds, on every play or pause, and on demand;
/// marks watched once, at the threshold `ProgressService` uses for Mydia.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'progress_reporter.dart';
import 'progress_service.dart';
import 'stream_timeline.dart';

abstract class PeriodicProgressReporter implements ProgressReporter {
  PeriodicProgressReporter({this.interval = const Duration(seconds: 10)});

  final Duration interval;

  @override
  StreamTimeline timeline = StreamTimeline.zero;

  Timer? _timer;
  StreamSubscription<bool>? _playing;
  ({int positionSeconds, int durationSeconds})? _last;
  bool _watchedSent = false;
  bool _stopped = false;

  @override
  void start(Player player,
      {required String mediaType, required String mediaId}) {
    stopSync();
    _timer = Timer.periodic(interval, (_) => unawaited(_report(player)));
    _playing = player.stream.playing.listen((_) => unawaited(_report(player)));
  }

  @override
  Future<void> save(
    Player player, {
    required String mediaType,
    required String mediaId,
  }) =>
      _report(player);

  @override
  bool isWatched(Player player) => ProgressService.isWatchedAt(
      player.state.position, player.state.duration, timeline);

  @override
  void stopSync() {
    _timer?.cancel();
    _timer = null;
    unawaited(_playing?.cancel());
    _playing = null;
  }

  /// Sends "stopped" at the last reported position: by now the player may
  /// already be gone.
  @override
  void dispose() {
    stopSync();
    final last = _last;
    if (last == null || _stopped) return;
    _stopped = true;
    unawaited(_guard(() => sendStopped(
          positionSeconds: last.positionSeconds,
          durationSeconds: last.durationSeconds,
        )));
  }

  Future<void> _report(Player player) async {
    final sync = ProgressService.resolveSync(
        player.state.position, player.state.duration, timeline);
    if (sync == null) return;
    _last = sync;
    await _guard(() => sendProgress(
          positionSeconds: sync.positionSeconds,
          durationSeconds: sync.durationSeconds,
          paused: !player.state.playing,
        ));
    if (!_watchedSent && isWatched(player)) {
      _watchedSent = true;
      await _guard(sendWatched);
    }
  }

  Future<void> _guard(Future<void> Function() send) async {
    try {
      await send();
    } catch (e) {
      debugPrint('[Progress] Could not report progress: $e');
    }
  }

  // Not @protected: the session tests call these directly, and a protected
  // call from a test is an analyzer warning, which the pre-commit gate
  // treats as fatal.

  /// One position report.
  Future<void> sendProgress({
    required int positionSeconds,
    required int durationSeconds,
    required bool paused,
  });

  /// The item crossed the watched threshold.
  Future<void> sendWatched();

  /// Playback ended at this position.
  Future<void> sendStopped({
    required int positionSeconds,
    required int durationSeconds,
  });
}
