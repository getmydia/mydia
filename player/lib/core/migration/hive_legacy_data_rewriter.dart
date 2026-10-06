/// Moves what the player stored under the legacy Mydia source id to the
/// migrated account's id. Every step is idempotent and writes only what
/// changes, so a rerun after a crash is safe.
library;

import 'package:flutter/foundation.dart';

import '../../domain/sources/item.dart';
import '../cast/cast_content.dart';
import '../cast/cast_session_store.dart';
import '../downloads/download_service.dart';
import '../playback/local_playback_progress.dart';
import '../playback/playback_progress_store.dart';
import '../sources/cache/source_cache.dart';
import '../sources/source.dart';
import '../sources/store/source_store.dart';
import 'legacy_mydia_migration.dart';

class HiveLegacyDataRewriter implements LegacyDataRewriter {
  HiveLegacyDataRewriter({
    required this.downloads,
    required this.progress,
    required this.store,
    required this.cache,
    required this.castSession,
  });

  /// Null where downloads are unsupported.
  final DownloadDatabase? downloads;
  final PlaybackProgressStore progress;
  final SourceStore store;
  final SourceCache cache;

  /// Null where cast sessions are not kept.
  final CastSessionStore? castSession;

  @override
  Future<void> rewrite(SourceId from, SourceId to) async {
    await _downloads(from, to);
    await _progress(from, to);
    await _sourceChoices(from, to);
    await cache.deletePrefix('${from.value}/');
    await _castSession(from, to);
  }

  Future<void> _downloads(SourceId from, SourceId to) async {
    final db = downloads;
    if (db == null) return;
    // A null sourceId is a record from before sources, so legacy Mydia.
    bool moves(String? id) => id == null || id == from.value;
    for (final task in db.getAllTasks()) {
      if (moves(task.sourceId)) {
        await db.saveTask(task.copyWith(sourceId: to.value));
      }
    }
    for (final media in db.getAllMedia()) {
      if (moves(media.sourceId)) {
        await db.saveMedia(media.copyWith(sourceId: to.value));
      }
    }
  }

  Future<void> _progress(SourceId from, SourceId to) async {
    for (final record in progress.all()) {
      if (record.sourceId != from.value) continue;
      final moved = LocalPlaybackProgress(
        sourceId: to.value,
        mediaId: record.mediaId,
        mediaType: record.mediaType,
        positionSeconds: record.positionSeconds,
        durationSeconds: record.durationSeconds,
        updatedAt: record.updatedAt,
        syncedAt: record.syncedAt,
      );
      // Save first: a crash leaves a duplicate, not a loss.
      await progress.save(moved);
      // Legacy records were keyed by the bare media id.
      await progress.delete(record.mediaId);
    }
  }

  Future<void> _sourceChoices(SourceId from, SourceId to) async {
    final snapshot = await store.load();
    if (snapshot.allServers.containsKey(from)) {
      await store.setAllServers({
        for (final e in snapshot.allServers.entries)
          (e.key == from ? to : e.key): e.value,
      });
    }
    if (snapshot.activeId == from) await store.setActive(to);
  }

  Future<void> _castSession(SourceId from, SourceId to) async {
    final castStore = castSession;
    if (castStore == null) return;
    try {
      final session = await castStore.load();
      // Records without a contentKind decode as Mydia content: left alone.
      if (session == null) return;
      final content = session.content;
      if (content is! SourceCastContent || content.item.sourceId != from) {
        return;
      }
      await castStore.save(PersistedCastSession.forContent(
        device: session.device,
        content: SourceCastContent(
          item: ItemRef(
            sourceId: to,
            kind: content.item.kind,
            externalId: content.item.externalId,
          ),
          versionId: content.versionId,
        ),
        title: session.title,
        position: session.position,
        routeKind: session.routeKind,
        savedAt: session.savedAt,
        mediaUrl: session.mediaUrl,
        duration: session.duration,
        selectedSubtitleTrackId: session.selectedSubtitleTrackId,
      ));
    } catch (e) {
      // A stale cast session is not worth failing the migration over.
      debugPrint('[Migration] Cast session left as is: $e');
    }
  }
}
