import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:media_kit/media_kit.dart';

import '../../graphql/mutations/update_movie_progress.graphql.dart';
import '../../graphql/mutations/update_episode_progress.graphql.dart';
import 'stream_timeline.dart';

/// Service for syncing playback progress to the server.
///
/// Handles periodic progress updates during playback and saves
/// final position when playback stops.
class ProgressService {
  final GraphQLClient _client;
  Timer? _syncTimer;
  DateTime? _lastSyncTime;

  static const _syncInterval = Duration(seconds: 10);
  static const _watchedThreshold = 0.90; // 90% completion

  /// The mapping from media_kit's stream-local positions onto real media
  /// positions. Set by the player screen once the streaming session is known;
  /// [StreamTimeline.zero] is correct for direct play and offline files.
  StreamTimeline timeline = StreamTimeline.zero;

  ProgressService(this._client);

  /// Starts syncing progress for a movie.
  ///
  /// Updates progress every 10 seconds while playing.
  void startMovieSync(
    Player player,
    String movieId,
  ) {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(_syncInterval, (_) {
      _syncMovieProgress(player, movieId);
    });
  }

  /// Starts syncing progress for an episode.
  ///
  /// Updates progress every 10 seconds while playing.
  void startEpisodeSync(
    Player player,
    String episodeId,
  ) {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(_syncInterval, (_) {
      _syncEpisodeProgress(player, episodeId);
    });
  }

  /// Stops the periodic sync timer.
  void stopSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  /// Saves movie progress immediately (call on pause/exit).
  Future<void> saveMovieProgress(
    Player player,
    String movieId,
  ) async {
    await _syncMovieProgress(player, movieId);
  }

  /// Saves episode progress immediately (call on pause/exit).
  Future<void> saveEpisodeProgress(
    Player player,
    String episodeId,
  ) async {
    await _syncEpisodeProgress(player, episodeId);
  }

  /// Resolves the position/duration to sync, preferring the authoritative
  /// [StreamTimeline] over the player's live duration.
  ///
  /// During HLS transcode the player reports a partial, still-growing
  /// duration (the playlist is built incrementally and the transcoder runs
  /// faster than realtime). Computing progress against it inflates the
  /// completion percentage — a few seconds of playback can read as ~30%.
  /// [timeline] carries the true full media duration, plus any resume start
  /// offset needed to translate [position] into real media time.
  ///
  /// Returns null when the data isn't valid to sync yet: duration unknown
  /// (still loading, failed load, error state — the server requires
  /// duration > 0), or position out of range.
  static ({int positionSeconds, int durationSeconds})? resolveSync(
    Duration position,
    Duration playerDuration,
    StreamTimeline timeline,
  ) {
    final duration = timeline.resolveDuration(playerDuration).inSeconds;
    final pos = timeline.toReal(position).inSeconds;

    if (duration <= 0) return null;
    if (pos < 0 || pos > duration) return null;

    return (positionSeconds: pos, durationSeconds: duration);
  }

  Future<void> _syncMovieProgress(
    Player player,
    String movieId,
  ) async {
    final progress = resolveSync(
      player.state.position,
      player.state.duration,
      timeline,
    );
    if (progress == null) {
      debugPrint(
        '[ProgressService] Skipping movie sync: invalid position/duration '
        '(position=${player.state.position.inSeconds}s, '
        'playerDuration=${player.state.duration.inSeconds}s, '
        'resolvedDuration=${timeline.resolveDuration(player.state.duration).inSeconds}s)',
      );
      return;
    }

    // Avoid syncing too frequently
    if (_lastSyncTime != null &&
        DateTime.now().difference(_lastSyncTime!) < _syncInterval) {
      return;
    }

    _lastSyncTime = DateTime.now();

    // Discarded deliberately: the periodic/manual player-driven sync has
    // never surfaced success/failure to its callers (`startMovieSync`,
    // `saveMovieProgress`) and does not start now — only the raw-position
    // entry points below (`syncMoviePosition`/`syncEpisodePosition`, used by
    // the cast receiver and the offline-progress flush) need to know.
    await _mutateMovieProgress(movieId, progress);
  }

  Future<void> _syncEpisodeProgress(
    Player player,
    String episodeId,
  ) async {
    final progress = resolveSync(
      player.state.position,
      player.state.duration,
      timeline,
    );
    if (progress == null) {
      debugPrint(
        '[ProgressService] Skipping episode sync: invalid position/duration '
        '(position=${player.state.position.inSeconds}s, '
        'playerDuration=${player.state.duration.inSeconds}s, '
        'resolvedDuration=${timeline.resolveDuration(player.state.duration).inSeconds}s)',
      );
      return;
    }

    // Avoid syncing too frequently
    if (_lastSyncTime != null &&
        DateTime.now().difference(_lastSyncTime!) < _syncInterval) {
      return;
    }

    _lastSyncTime = DateTime.now();

    // Discarded — see the matching comment in `_syncMovieProgress`.
    await _mutateEpisodeProgress(episodeId, progress);
  }

  /// Sync movie progress from a raw position, for playback we do not own —
  /// notably a cast receiver, where there is no local `Player` to read.
  ///
  /// Returns whether the server actually received it: false when nothing was
  /// sent at all (an invalid position/duration), or when the mutation was
  /// sent but failed. Callers that need to know the server has the position —
  /// e.g. before marking an offline-recorded record synced — must check this
  /// rather than assume `await` completing means success.
  Future<bool> syncMoviePosition(
    String movieId,
    Duration position,
    Duration duration,
  ) async {
    final progress = resolveSync(position, duration, timeline);
    if (progress == null) {
      debugPrint(
        '[ProgressService] Skipping movie sync: invalid position/duration '
        '(position=${position.inSeconds}s, duration=${duration.inSeconds}s)',
      );
      return false;
    }

    return _mutateMovieProgress(movieId, progress);
  }

  /// Sync episode progress from a raw position. See [syncMoviePosition].
  Future<bool> syncEpisodePosition(
    String episodeId,
    Duration position,
    Duration duration,
  ) async {
    final progress = resolveSync(position, duration, timeline);
    if (progress == null) {
      debugPrint(
        '[ProgressService] Skipping episode sync: invalid position/duration '
        '(position=${position.inSeconds}s, duration=${duration.inSeconds}s)',
      );
      return false;
    }

    return _mutateEpisodeProgress(episodeId, progress);
  }

  /// Returns true only when the mutation reached the server with no
  /// exception thrown and no GraphQL exception in the result.
  Future<bool> _mutateMovieProgress(
    String movieId,
    ({int positionSeconds, int durationSeconds}) progress,
  ) async {
    try {
      debugPrint(
        '[ProgressService] Syncing movie progress: movieId=$movieId, '
        'position=${progress.positionSeconds}, duration=${progress.durationSeconds}',
      );

      final result = await _client.mutate(MutationOptions(
        document: documentNodeMutationUpdateMovieProgress,
        variables: Variables$Mutation$UpdateMovieProgress(
          movieId: movieId,
          positionSeconds: progress.positionSeconds,
          durationSeconds: progress.durationSeconds,
        ).toJson(),
      ));

      if (result.hasException) {
        debugPrint(
            '[ProgressService] Error syncing movie progress: ${result.exception}');
        return false;
      }

      return true;
    } catch (e) {
      debugPrint('[ProgressService] Exception syncing movie progress: $e');
      return false;
    }
  }

  /// Returns true only when the mutation reached the server with no
  /// exception thrown and no GraphQL exception in the result.
  Future<bool> _mutateEpisodeProgress(
    String episodeId,
    ({int positionSeconds, int durationSeconds}) progress,
  ) async {
    try {
      debugPrint(
        '[ProgressService] Syncing episode progress: episodeId=$episodeId, '
        'position=${progress.positionSeconds}, duration=${progress.durationSeconds}',
      );

      final result = await _client.mutate(MutationOptions(
        document: documentNodeMutationUpdateEpisodeProgress,
        variables: Variables$Mutation$UpdateEpisodeProgress(
          episodeId: episodeId,
          positionSeconds: progress.positionSeconds,
          durationSeconds: progress.durationSeconds,
        ).toJson(),
      ));

      if (result.hasException) {
        debugPrint(
            '[ProgressService] Error syncing episode progress: ${result.exception}');
        return false;
      }

      return true;
    } catch (e) {
      debugPrint('[ProgressService] Exception syncing episode progress: $e');
      return false;
    }
  }

  /// Checks if the current playback position indicates the content is watched.
  ///
  /// Returns true if position is >= 90% of duration.
  bool isWatched(Player player) =>
      isWatchedAt(player.state.position, player.state.duration, timeline);

  /// Whether a position counts as watched, without needing a `Player`.
  static bool isWatchedAt(
    Duration position,
    Duration playerDuration,
    StreamTimeline timeline,
  ) {
    final seconds = timeline.resolveDuration(playerDuration).inSeconds;
    if (seconds <= 0) return false;

    return (timeline.toReal(position).inSeconds / seconds) >= _watchedThreshold;
  }

  /// Disposes the service and cancels any active timers.
  void dispose() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }
}
