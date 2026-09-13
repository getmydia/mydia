/// Providers for collection auto-sync persistence.
///
/// Stores sync configuration per collection in a Hive box.
/// Each entry maps a collection ID to {name, resolution}.
library;

import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'collection_sync_providers.g.dart';

/// Box name for collection sync settings.
const String _collectionSyncBoxName = 'collection_sync';

/// Provider for the collection sync Hive box.
@Riverpod(keepAlive: true)
Future<Box<Map>> collectionSyncBox(Ref ref) async {
  return Hive.openBox<Map>(_collectionSyncBoxName);
}

/// Whether a specific collection is configured for auto-sync.
@riverpod
Future<bool> isCollectionSynced(Ref ref, String collectionId) async {
  final box = await ref.watch(collectionSyncBoxProvider.future);
  return box.containsKey(collectionId);
}

/// Get the sync config for a collection, or null if not synced.
/// Returns a map with 'name' and 'resolution' keys.
@riverpod
Future<Map<String, String>?> collectionSyncConfig(
  Ref ref,
  String collectionId,
) async {
  final box = await ref.watch(collectionSyncBoxProvider.future);
  final raw = box.get(collectionId);
  if (raw == null) return null;
  return Map<String, String>.from(raw);
}

/// Get all synced collection configs.
/// Returns a map of collectionId -> {name, resolution}.
@riverpod
Future<Map<String, Map<String, String>>> allSyncedCollections(Ref ref) async {
  final box = await ref.watch(collectionSyncBoxProvider.future);
  final result = <String, Map<String, String>>{};
  for (final key in box.keys) {
    final raw = box.get(key);
    if (raw != null) {
      result[key as String] = Map<String, String>.from(raw);
    }
  }
  return result;
}

/// Save a collection sync config.
///
/// `keepAlive` is load-bearing, not a memory choice: the closure invalidates
/// after its `await`, and call sites reach this provider with `ref.read` while
/// nothing watches it. See `player/docs/riverpod.md` for why an unwatched
/// autoDispose provider cannot hold a Ref across an await (#744).
@Riverpod(keepAlive: true)
Future<void> Function({
  required String collectionId,
  required String name,
  required String resolution,
}) saveCollectionSync(Ref ref) {
  return ({
    required String collectionId,
    required String name,
    required String resolution,
  }) async {
    final box = await ref.read(collectionSyncBoxProvider.future);
    await box.put(collectionId, {'name': name, 'resolution': resolution});
    ref.invalidate(isCollectionSyncedProvider(collectionId));
    ref.invalidate(collectionSyncConfigProvider(collectionId));
    ref.invalidate(allSyncedCollectionsProvider);
  };
}

/// Remove a collection sync config.
///
/// `keepAlive` for the same reason as [saveCollectionSync].
@Riverpod(keepAlive: true)
Future<void> Function(String collectionId) removeCollectionSync(Ref ref) {
  return (String collectionId) async {
    final box = await ref.read(collectionSyncBoxProvider.future);
    await box.delete(collectionId);
    ref.invalidate(isCollectionSyncedProvider(collectionId));
    ref.invalidate(collectionSyncConfigProvider(collectionId));
    ref.invalidate(allSyncedCollectionsProvider);
  };
}
