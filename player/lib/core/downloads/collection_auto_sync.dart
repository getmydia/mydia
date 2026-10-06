/// Auto-syncs collections configured for offline download.
library;

import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../router/legacy_routes.dart';
import '../sources/source.dart';
import '../sources/sources_providers.dart';
import 'collection_sync_providers.dart';
import 'collection_sync_service.dart';
import 'download_providers.dart';
import 'summary_download_metadata.dart';

typedef NowFn = DateTime Function();
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// Debounced auto-sync for all collections with sync enabled.
class CollectionAutoSync {
  final ProviderReader _read;
  final NowFn now;
  DateTime? _lastRunTime;
  AppLifecycleListener? _lifecycleListener;
  void Function(int queued)? onQueued;

  CollectionAutoSync._({
    required ProviderReader read,
    NowFn? now,
  })  : _read = read,
        now = now ?? DateTime.now;

  factory CollectionAutoSync(WidgetRef ref, {NowFn? now}) {
    return CollectionAutoSync._(read: ref.read, now: now);
  }

  @visibleForTesting
  factory CollectionAutoSync.forTest({
    required ProviderReader read,
    NowFn? now,
  }) {
    return CollectionAutoSync._(read: read, now: now);
  }

  static const _debounce = Duration(minutes: 5);

  /// Wires resume and first-frame triggers when [enabled] is true.
  void install({
    required bool enabled,
    void Function(int queued)? onQueued,
  }) {
    this.onQueued = onQueued;
    if (!enabled || kIsWeb) return;

    _lifecycleListener ??= AppLifecycleListener(
      onResume: () {
        debugPrint('[CollectionAutoSync] App resumed from background');
        _notifyQueued();
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _notifyQueued());
  }

  Future<void> _notifyQueued() async {
    final queued = await run();
    onQueued?.call(queued);
  }

  void dispose() {
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
  }

  /// Returns the number of items newly queued for download.
  Future<int> run() async {
    final current = now();
    if (_lastRunTime != null && current.difference(_lastRunTime!) < _debounce) {
      debugPrint('[CollectionAutoSync] Skipping auto-sync (debounced)');
      return 0;
    }
    _lastRunTime = current;

    try {
      final Map<String, Map<String, String>> syncConfigs =
          await _read(allSyncedCollectionsProvider.future);
      if (syncConfigs.isEmpty) return 0;

      debugPrint(
        '[CollectionAutoSync] Auto-syncing ${syncConfigs.length} collection(s)',
      );

      var totalQueued = 0;
      for (final entry in syncConfigs.entries) {
        final config = entry.value;
        final collectionId = config['collectionId'] ?? entry.key;
        final resolution = config['resolution'];
        if (resolution == null) continue;

        try {
          // A config saved before sources were addressable belongs to the
          // migrated legacy instance, which is where it was made.
          final configSourceId = config['sourceId'];
          final sourceId = configSourceId == null
              ? _read(legacyMydiaSourceIdProvider)
              : SourceId(configSourceId);
          final source =
              sourceId == null ? null : _read(mediaSourceProvider(sourceId));
          if (source == null) continue;

          final items = await allCollectionItems(source, collectionId);
          if (items.isEmpty) continue;

          final manager = await _read(downloadManagerProvider.future);
          final result = await syncCollectionItems(
            source: source,
            items: items,
            optionId: resolution,
            manager: manager,
            queue: manager.getActiveDownloads(),
            metadataFor: summaryDownloadMetadata,
          );
          totalQueued += result.totalQueued;

          if (result.hasNewDownloads) {
            debugPrint(
              '[CollectionAutoSync] Auto-sync: ${config['name']} - '
              '${result.moviesQueued} movies, '
              '${result.episodesQueued} episodes queued',
            );
          }
        } catch (e) {
          debugPrint(
            '[CollectionAutoSync] Auto-sync failed for ${config['name']}: $e',
          );
        }
      }

      return totalQueued;
    } catch (e) {
      debugPrint('[CollectionAutoSync] Auto-sync error: $e');
      return 0;
    }
  }
}

/// Factory for creating a [CollectionAutoSync] bound to a [WidgetRef].
final collectionAutoSyncProvider =
    Provider<CollectionAutoSync Function(WidgetRef)>(
  (ref) => CollectionAutoSync.new,
);
