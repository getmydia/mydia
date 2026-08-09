/// Auto-syncs collections configured for offline download.
library;

import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../presentation/screens/collections/collection_detail_controller.dart';
import '../../domain/models/recently_added_item.dart';
import 'collection_sync_providers.dart';
import 'collection_sync_service.dart';

typedef NowFn = DateTime Function();
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// Debounced auto-sync for all collections with sync enabled.
class CollectionAutoSync {
  final ProviderReader _read;
  final WidgetRef? _widgetRef;
  final NowFn now;
  DateTime? _lastRunTime;
  AppLifecycleListener? _lifecycleListener;
  void Function(int queued)? onQueued;

  CollectionAutoSync._({
    required ProviderReader read,
    WidgetRef? widgetRef,
    NowFn? now,
  })  : _read = read,
        _widgetRef = widgetRef,
        now = now ?? DateTime.now;

  factory CollectionAutoSync(WidgetRef ref, {NowFn? now}) {
    return CollectionAutoSync._(read: ref.read, widgetRef: ref, now: now);
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

      final widgetRef = _widgetRef;
      if (widgetRef == null) return 0;

      var totalQueued = 0;
      for (final entry in syncConfigs.entries) {
        final collectionId = entry.key;
        final config = entry.value;
        final resolution = config['resolution'];
        if (resolution == null) continue;

        try {
          final List<RecentlyAddedItem> items = await _read(
            collectionDetailControllerProvider(collectionId).future,
          );

          if (items.isEmpty) continue;

          final result = await syncCollectionItems(
            items: items,
            resolution: resolution,
            ref: widgetRef,
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
