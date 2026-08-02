import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../player/progress_service.dart';
import 'local_playback_progress.dart';

abstract class PlaybackProgressStore {
  Future<void> save(LocalPlaybackProgress progress);

  /// Synchronous so the resume decision can read it without an extra await on
  /// a path that is already several awaits deep. Hive keeps an open box in
  /// memory, so there is nothing to wait for.
  LocalPlaybackProgress? get(String mediaId);

  List<LocalPlaybackProgress> unsynced();

  Future<void> markSynced(String mediaId, DateTime syncedAt);
}

/// Hive-backed store over a plain `Box<Map>` with no type adapter, matching
/// `HiveCastSessionStore` and `collection_sync_providers.dart`.
class HivePlaybackProgressStore implements PlaybackProgressStore {
  static const boxName = 'playback_progress';

  final Box<Map> _box;

  const HivePlaybackProgressStore(this._box);

  @override
  Future<void> save(LocalPlaybackProgress progress) async {
    await _box.put(progress.mediaId, progress.toMap());
  }

  @override
  LocalPlaybackProgress? get(String mediaId) {
    final raw = _box.get(mediaId);
    if (raw == null) return null;

    try {
      return LocalPlaybackProgress.fromMap(raw);
    } catch (e) {
      // A malformed record must never cost the user their playback.
      debugPrint('[PlaybackProgressStore] Discarding unreadable record: $e');
      unawaited(_box.delete(mediaId));
      return null;
    }
  }

  @override
  List<LocalPlaybackProgress> unsynced() {
    final out = <LocalPlaybackProgress>[];
    for (final key in _box.keys) {
      final record = get(key as String);
      if (record != null && !record.isSynced) out.add(record);
    }
    return out;
  }

  @override
  Future<void> markSynced(String mediaId, DateTime syncedAt) async {
    final existing = get(mediaId);
    if (existing == null) return;
    await save(existing.copyWith(syncedAt: syncedAt));
  }
}

class InMemoryPlaybackProgressStore implements PlaybackProgressStore {
  final _records = <String, LocalPlaybackProgress>{};

  @override
  Future<void> save(LocalPlaybackProgress progress) async {
    _records[progress.mediaId] = progress;
  }

  @override
  LocalPlaybackProgress? get(String mediaId) => _records[mediaId];

  @override
  List<LocalPlaybackProgress> unsynced() =>
      _records.values.where((p) => !p.isSynced).toList();

  @override
  Future<void> markSynced(String mediaId, DateTime syncedAt) async {
    final existing = _records[mediaId];
    if (existing == null) return;
    _records[mediaId] = existing.copyWith(syncedAt: syncedAt);
  }
}

/// Which side holds the position worth resuming from.
///
/// Compared on timestamp rather than fixed precedence, so finishing an episode
/// on the TV beats a stale offline position on the phone, and an offline
/// session beats a server record from last week.
///
/// A server record with no `lastWatchedAt` cannot be compared, so a local
/// record wins over it rather than being silently overridden by something
/// that may be much older.
({int? positionSeconds, int? durationSeconds}) pickNewerProgress({
  required LocalPlaybackProgress? local,
  required int? serverPositionSeconds,
  required int? serverDurationSeconds,
  required DateTime? serverLastWatchedAt,
}) {
  if (local == null) {
    return (
      positionSeconds: serverPositionSeconds,
      durationSeconds: serverDurationSeconds,
    );
  }

  final localWins = serverPositionSeconds == null ||
      serverLastWatchedAt == null ||
      !serverLastWatchedAt.isAfter(local.updatedAt);

  if (localWins) {
    return (
      positionSeconds: local.positionSeconds,
      durationSeconds: local.durationSeconds,
    );
  }

  return (
    positionSeconds: serverPositionSeconds,
    durationSeconds: serverDurationSeconds ?? local.durationSeconds,
  );
}

/// Records a position locally, swallowing every failure.
///
/// A store write must never cost the user their playback, so this mirrors the
/// error policy `_fetchProgressAndEpisodes` already uses. A non-positive
/// duration is dropped rather than stored: a percentage against it is
/// meaningless, and the server's own progress mutation rejects it.
Future<void> recordLocalProgress({
  required PlaybackProgressStore store,
  required String mediaId,
  required String mediaType,
  required Duration position,
  required Duration duration,
  required DateTime now,
}) async {
  if (duration <= Duration.zero) return;
  if (position < Duration.zero) return;

  try {
    await store.save(LocalPlaybackProgress(
      mediaId: mediaId,
      mediaType: mediaType,
      positionSeconds: position.inSeconds,
      durationSeconds: duration.inSeconds,
      updatedAt: now,
    ));
  } catch (e) {
    debugPrint('[PlaybackProgressStore] Ignoring failed local write: $e');
  }
}

/// Pushes every locally-recorded position the server does not have yet.
///
/// Records are attempted independently: one unreachable item must not strand
/// the rest of the queue. A failure leaves `syncedAt` null so the next
/// reconnect tries again.
Future<int> flushUnsyncedProgress({
  required PlaybackProgressStore store,
  required ProgressService progressService,
  required DateTime now,
}) async {
  var synced = 0;

  for (final record in store.unsynced()) {
    final position = Duration(seconds: record.positionSeconds);
    final duration = Duration(seconds: record.durationSeconds);

    try {
      if (record.mediaType == 'episode') {
        await progressService.syncEpisodePosition(
            record.mediaId, position, duration);
      } else {
        await progressService.syncMoviePosition(
            record.mediaId, position, duration);
      }
      await store.markSynced(record.mediaId, now);
      synced++;
    } catch (e) {
      debugPrint(
          '[PlaybackProgressStore] Deferring sync for ${record.mediaId}: $e');
    }
  }

  return synced;
}
