/// Providers for collection auto-sync persistence.
///
/// Stores sync configuration per collection in a Hive box, keyed by
/// [collectionSyncKey] so two instances that both have a collection `1` stay
/// apart. Each entry holds {name, resolution, sourceId, collectionId}.
///
/// Entries saved before sources were addressable are keyed by the bare
/// collection id and belong to the bound Mydia instance (or to the
/// `sourceId` they recorded). They are still read, and a save or removal
/// moves them to the new key.
library;

import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../sources/mydia/bound_mydia.dart';

part 'collection_sync_providers.g.dart';

/// Box name for collection sync settings.
const String _collectionSyncBoxName = 'collection_sync';

/// The box key of [collectionId] on the source [sourceId].
String collectionSyncKey(String sourceId, String collectionId) =>
    '$sourceId:$collectionId';

/// Provider for the collection sync Hive box.
@Riverpod(keepAlive: true)
Future<Box<Map<dynamic, dynamic>>> collectionSyncBox(Ref ref) async {
  return Hive.openBox<Map<dynamic, dynamic>>(_collectionSyncBoxName);
}

/// The entry for [collectionId] on [sourceId] and the key it is stored
/// under, preferring the current key over a legacy one.
({String key, Map<String, String> config})? _find(
  Box<Map<dynamic, dynamic>> box,
  String sourceId,
  String collectionId,
  String? boundSourceId,
) {
  final key = collectionSyncKey(sourceId, collectionId);
  final current = box.get(key);
  if (current != null) {
    return (key: key, config: Map<String, String>.from(current));
  }
  final legacy = box.get(collectionId);
  if (legacy == null) return null;
  final config = Map<String, String>.from(legacy);
  final owner = config['sourceId'] ?? boundSourceId;
  return owner == sourceId ? (key: collectionId, config: config) : null;
}

/// Whether a specific collection is configured for auto-sync.
@riverpod
Future<bool> isCollectionSynced(
  Ref ref,
  String sourceId,
  String collectionId,
) async {
  final box = await ref.watch(collectionSyncBoxProvider.future);
  final bound = ref.watch(boundSourceIdProvider)?.value;
  return _find(box, sourceId, collectionId, bound) != null;
}

/// Get the sync config for a collection, or null if not synced.
/// Returns a map with 'name' and 'resolution' keys.
@riverpod
Future<Map<String, String>?> collectionSyncConfig(
  Ref ref,
  String sourceId,
  String collectionId,
) async {
  final box = await ref.watch(collectionSyncBoxProvider.future);
  final bound = ref.watch(boundSourceIdProvider)?.value;
  return _find(box, sourceId, collectionId, bound)?.config;
}

/// Get all synced collection configs.
/// Returns a map of box key -> {name, resolution, sourceId, collectionId}.
/// A legacy entry reports the ids it belongs to, so the caller never has to
/// parse a key.
@riverpod
Future<Map<String, Map<String, String>>> allSyncedCollections(Ref ref) async {
  final box = await ref.watch(collectionSyncBoxProvider.future);
  final bound = ref.watch(boundSourceIdProvider)?.value;
  final result = <String, Map<String, String>>{};
  for (final key in box.keys) {
    final raw = box.get(key);
    if (raw == null) continue;
    final config = Map<String, String>.from(raw);
    config['collectionId'] ??= key as String;
    if (config['sourceId'] == null && bound != null) {
      config['sourceId'] = bound;
    }
    result[key as String] = config;
  }
  return result;
}

void _invalidate(Ref ref, String sourceId, String collectionId) {
  ref.invalidate(isCollectionSyncedProvider(sourceId, collectionId));
  ref.invalidate(collectionSyncConfigProvider(sourceId, collectionId));
  ref.invalidate(allSyncedCollectionsProvider);
}

/// Save a collection sync config.
///
/// `keepAlive` is load-bearing, not a memory choice: the closure invalidates
/// after its `await`, and call sites reach this provider with `ref.read` while
/// nothing watches it. See `player/docs/riverpod.md` for why an unwatched
/// autoDispose provider cannot hold a Ref across an await (#744).
@Riverpod(keepAlive: true)
Future<void> Function({
  required String sourceId,
  required String collectionId,
  required String name,
  required String resolution,
}) saveCollectionSync(Ref ref) {
  return ({
    required String sourceId,
    required String collectionId,
    required String name,
    required String resolution,
  }) async {
    final box = await ref.read(collectionSyncBoxProvider.future);
    final bound = ref.read(boundSourceIdProvider)?.value;
    final found = _find(box, sourceId, collectionId, bound);
    await box.put(collectionSyncKey(sourceId, collectionId), {
      'name': name,
      'resolution': resolution,
      'sourceId': sourceId,
      'collectionId': collectionId,
    });
    // Moves a legacy entry to the new key.
    if (found != null && found.key == collectionId) {
      await box.delete(collectionId);
    }
    _invalidate(ref, sourceId, collectionId);
  };
}

/// Remove a collection sync config.
///
/// `keepAlive` for the same reason as [saveCollectionSync].
@Riverpod(keepAlive: true)
Future<void> Function(String sourceId, String collectionId)
    removeCollectionSync(Ref ref) {
  return (String sourceId, String collectionId) async {
    final box = await ref.read(collectionSyncBoxProvider.future);
    final bound = ref.read(boundSourceIdProvider)?.value;
    final found = _find(box, sourceId, collectionId, bound);
    if (found != null) await box.delete(found.key);
    _invalidate(ref, sourceId, collectionId);
  };
}
