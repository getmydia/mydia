import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../../domain/sources/item.dart';
import '../player/progress_service.dart';
import '../sources/capabilities.dart';
import '../sources/source.dart';
import 'local_playback_progress.dart';

abstract class PlaybackProgressStore {
  Future<void> save(LocalPlaybackProgress progress);

  /// [key] is a [progressKey]: the bare id for home Mydia, `source|id` for
  /// the rest.
  ///
  /// Synchronous so the resume decision can read it without an extra await on
  /// a path that is already several awaits deep. Hive keeps an open box in
  /// memory, so there is nothing to wait for.
  LocalPlaybackProgress? get(String key);

  List<LocalPlaybackProgress> unsynced();

  /// [key] is a [progressKey].
  Future<void> markSynced(String key, DateTime syncedAt);
}

/// Hive-backed store over a plain `Box<Map>` with no type adapter, matching
/// `HiveCastSessionStore` and `collection_sync_providers.dart`.
class HivePlaybackProgressStore implements PlaybackProgressStore {
  static const boxName = 'playback_progress';

  final Box<Map<dynamic, dynamic>> _box;

  const HivePlaybackProgressStore(this._box);

  @override
  Future<void> save(LocalPlaybackProgress progress) async {
    await _box.put(progress.key, progress.toMap());
  }

  @override
  LocalPlaybackProgress? get(String key) {
    final raw = _box.get(key);
    if (raw == null) return null;

    try {
      return LocalPlaybackProgress.fromMap(raw);
    } catch (e) {
      // A malformed record must never cost the user their playback.
      debugPrint('[PlaybackProgressStore] Discarding unreadable record: $e');
      unawaited(_box.delete(key));
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
  Future<void> markSynced(String key, DateTime syncedAt) async {
    final existing = get(key);
    if (existing == null) return;
    await save(existing.copyWith(syncedAt: syncedAt));
  }
}

class InMemoryPlaybackProgressStore implements PlaybackProgressStore {
  final _records = <String, LocalPlaybackProgress>{};

  @override
  Future<void> save(LocalPlaybackProgress progress) async {
    _records[progress.key] = progress;
  }

  @override
  LocalPlaybackProgress? get(String key) => _records[key];

  @override
  List<LocalPlaybackProgress> unsynced() =>
      _records.values.where((p) => !p.isSynced).toList();

  @override
  Future<void> markSynced(String key, DateTime syncedAt) async {
    final existing = _records[key];
    if (existing == null) return;
    _records[key] = existing.copyWith(syncedAt: syncedAt);
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
  required ItemRef item,
  required String mediaType,
  required Duration position,
  required Duration duration,
  required DateTime now,
}) async {
  if (duration <= Duration.zero) return;
  if (position < Duration.zero) return;

  try {
    await store.save(LocalPlaybackProgress(
      sourceId: item.sourceId.value,
      mediaId: item.externalId,
      mediaType: mediaType,
      positionSeconds: position.inSeconds,
      durationSeconds: duration.inSeconds,
      updatedAt: now,
    ));
  } catch (e) {
    debugPrint('[PlaybackProgressStore] Ignoring failed local write: $e');
  }
}

/// Records a downloaded item's position locally *and* pushes it to the
/// server, marking the local record synced only if the server took it.
///
/// This is the online half of the downloaded-media path. [recordLocalProgress]
/// always writes `syncedAt: null`, meaning "the server does not have this
/// yet" — true while offline, but wrong the moment the very same save also
/// reaches the server. Left unmarked, those records pile up as permanently
/// unsynced, and the first [flushUnsyncedProgress] after offline detection is
/// reinstated would replay a queue of stale positions over newer server
/// progress.
///
/// The same [position] and [duration] go to both sides, so "synced" means the
/// two genuinely agree. `sync*Position` is used rather than
/// `save*Progress` for two reasons: it reports whether the server actually
/// accepted the write, and it is not subject to the periodic sync's 10 second
/// throttle, which would otherwise make a save-on-exit report failure simply
/// because the timer had fired recently.
///
/// Marking is never optimistic: a `false` return (nothing sent, or sent and
/// rejected) and a throw both leave `syncedAt` null for a later flush to
/// retry.
Future<void> saveDownloadedProgress({
  required PlaybackProgressStore store,
  required ProgressService progressService,
  required ItemRef item,
  required String mediaType,
  required Duration position,
  required Duration duration,
  required DateTime now,
}) async {
  final mediaId = item.externalId;
  await recordLocalProgress(
    store: store,
    item: item,
    mediaType: mediaType,
    position: position,
    duration: duration,
    now: now,
  );

  final bool accepted;
  try {
    accepted = mediaType == 'episode'
        ? await progressService.syncEpisodePosition(mediaId, position, duration)
        : await progressService.syncMoviePosition(mediaId, position, duration);
  } catch (e) {
    debugPrint(
        '[PlaybackProgressStore] Server save for $mediaId failed, leaving it unsynced: $e');
    return;
  }

  if (!accepted) {
    debugPrint(
        '[PlaybackProgressStore] Server did not accept $mediaId, leaving it unsynced');
    return;
  }

  try {
    await store.markSynced(progressKey(item), now);
  } catch (e) {
    // Same policy as `recordLocalProgress`: a store write must never cost the
    // user their playback. The record simply stays queued for a later flush.
    debugPrint('[PlaybackProgressStore] Ignoring failed synced-marking: $e');
  }
}

/// Pushes every locally-recorded position the server does not have yet.
///
/// Records are attempted independently: one unreachable item must not strand
/// the rest of the queue. A record is only marked synced when
/// `ProgressService` reports the server actually received it — its `false`
/// return covers both "nothing was sent" (an invalid position/duration) and
/// "sent but rejected/failed" — so a flaky reconnect can no longer discard
/// progress the local store exists to protect. The try/catch is a
/// belt-and-braces guard for a future throwing implementation; `false` is the
/// primary failure signal today. Either way, a failure leaves `syncedAt` null
/// so the next reconnect retries — indefinitely, for a record the server
/// keeps rejecting; there is no dead-letter handling.
Future<int> flushUnsyncedProgress({
  required PlaybackProgressStore store,
  required ProgressService progressService,
  required DateTime now,
}) async {
  var synced = 0;

  final home =
      store.unsynced().where((r) => r.sourceId == SourceId.legacyMydia.value);
  for (final record in home) {
    final position = Duration(seconds: record.positionSeconds);
    final duration = Duration(seconds: record.durationSeconds);

    try {
      final ok = record.mediaType == 'episode'
          ? await progressService.syncEpisodePosition(
              record.mediaId, position, duration)
          : await progressService.syncMoviePosition(
              record.mediaId, position, duration);

      if (!ok) {
        debugPrint(
            '[PlaybackProgressStore] Server did not accept sync for ${record.mediaId}, leaving unsynced');
        continue;
      }

      await store.markSynced(record.key, now);
      synced++;
    } catch (e) {
      debugPrint(
          '[PlaybackProgressStore] Deferring sync for ${record.mediaId}: $e');
    }
  }

  return synced;
}

/// Hands every source its positions recorded while out of reach. Pushes
/// unconditionally, as the home flush does: newer-wins is decided at play
/// time by [pickNewerProgress]. Records of sources that are gone, out of
/// reach, or refuse the push stay unsynced for the next run.
Future<int> flushSourceProgress({
  required PlaybackProgressStore store,
  required ProgressSync? Function(SourceId id) syncFor,
  required bool Function(SourceId id) reachable,
  required DateTime now,
}) async {
  var synced = 0;
  for (final record in store.unsynced()) {
    if (record.sourceId == SourceId.legacyMydia.value) continue;
    final id = SourceId(record.sourceId);
    final sync = syncFor(id);
    if (sync == null || !reachable(id)) continue;
    final ref = ItemRef(
      sourceId: id,
      kind: record.mediaType == 'episode' ? ItemKind.episode : ItemKind.movie,
      externalId: record.mediaId,
    );
    try {
      await sync.pushProgress(
        ref,
        positionSeconds: record.positionSeconds,
        durationSeconds: record.durationSeconds,
        watched: record.durationSeconds > 0 &&
            record.positionSeconds / record.durationSeconds >=
                ProgressService.watchedThreshold,
      );
      await store.markSynced(record.key, now);
      synced++;
    } catch (e) {
      debugPrint('[PlaybackProgressStore] Deferring ${record.key}: $e');
    }
  }
  return synced;
}
