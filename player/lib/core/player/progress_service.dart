import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:media_kit/media_kit.dart';

import '../../graphql/mutations/update_movie_progress.graphql.dart';
import '../../graphql/mutations/update_episode_progress.graphql.dart';

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

  Future<void> _syncMovieProgress(
    Player player,
    String movieId,
  ) async {
    final position = player.state.position.inSeconds;
    final duration = player.state.duration.inSeconds;

    // Skip if duration not yet available or invalid (server requires duration > 0)
    // This can happen when:
    // - Media is still loading
    // - Media failed to load (e.g., invalid URL scheme like p2p://)
    // - Player is in an error state
    if (duration <= 0) {
      debugPrint(
          '[ProgressService] Skipping movie sync: duration=$duration (invalid)');
      return;
    }

    // Additional sanity check: position should be within valid range
    if (position < 0 || position > duration) {
      debugPrint(
          '[ProgressService] Skipping movie sync: position=$position out of range (0-$duration)');
      return;
    }

    // Avoid syncing too frequently
    if (_lastSyncTime != null &&
        DateTime.now().difference(_lastSyncTime!) < _syncInterval) {
      return;
    }

    try {
      _lastSyncTime = DateTime.now();

      debugPrint(
          '[ProgressService] Syncing movie progress: movieId=$movieId, position=$position, duration=$duration');

      // Final safety check - never send invalid duration
      if (duration <= 0) {
        debugPrint(
            '[ProgressService] UNEXPECTED: duration=$duration after checks, aborting');
        return;
      }

      final options = MutationOptions(
        document: documentNodeMutationUpdateMovieProgress,
        variables: Variables$Mutation$UpdateMovieProgress(
          movieId: movieId,
          positionSeconds: position,
          durationSeconds: duration,
        ).toJson(),
      );

      final result = await _client.mutate(options);

      if (result.hasException) {
        debugPrint(
            '[ProgressService] Error syncing movie progress: ${result.exception}');
      } else {
        debugPrint('[ProgressService] Movie progress synced successfully');
      }
    } catch (e) {
      debugPrint('[ProgressService] Exception syncing movie progress: $e');
    }
  }

  Future<void> _syncEpisodeProgress(
    Player player,
    String episodeId,
  ) async {
    final position = player.state.position.inSeconds;
    final duration = player.state.duration.inSeconds;

    // Skip if duration not yet available or invalid (server requires duration > 0)
    // This can happen when:
    // - Media is still loading
    // - Media failed to load (e.g., invalid URL scheme like p2p://)
    // - Player is in an error state
    if (duration <= 0) {
      debugPrint(
          '[ProgressService] Skipping episode sync: duration=$duration (invalid)');
      return;
    }

    // Additional sanity check: position should be within valid range
    if (position < 0 || position > duration) {
      debugPrint(
          '[ProgressService] Skipping episode sync: position=$position out of range (0-$duration)');
      return;
    }

    // Avoid syncing too frequently
    if (_lastSyncTime != null &&
        DateTime.now().difference(_lastSyncTime!) < _syncInterval) {
      return;
    }

    try {
      _lastSyncTime = DateTime.now();

      debugPrint(
          '[ProgressService] Syncing episode progress: episodeId=$episodeId, position=$position, duration=$duration');

      // Final safety check - never send invalid duration
      if (duration <= 0) {
        debugPrint(
            '[ProgressService] UNEXPECTED: duration=$duration after checks, aborting');
        return;
      }

      final options = MutationOptions(
        document: documentNodeMutationUpdateEpisodeProgress,
        variables: Variables$Mutation$UpdateEpisodeProgress(
          episodeId: episodeId,
          positionSeconds: position,
          durationSeconds: duration,
        ).toJson(),
      );

      final result = await _client.mutate(options);

      if (result.hasException) {
        debugPrint(
            '[ProgressService] Error syncing episode progress: ${result.exception}');
      } else {
        debugPrint('[ProgressService] Episode progress synced successfully');
      }
    } catch (e) {
      debugPrint('[ProgressService] Exception syncing episode progress: $e');
    }
  }

  /// Checks if the current playback position indicates the content is watched.
  ///
  /// Returns true if position is >= 90% of duration.
  bool isWatched(Player player) {
    final position = player.state.position.inSeconds;
    final duration = player.state.duration.inSeconds;

    if (duration == 0) return false;

    return (position / duration) >= _watchedThreshold;
  }

  /// Disposes the service and cancels any active timers.
  void dispose() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }
}
