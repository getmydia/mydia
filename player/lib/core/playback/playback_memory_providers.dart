import 'dart:io' show FileSystemException;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';

import 'playback_memory.dart';

/// Returns true if [error] indicates an on-disk box corruption rather than a
/// transient file system error or configuration issue.
bool isBoxCorruptionError(Object error) {
  if (error is FileSystemException) return false;
  final msg = error.toString().toLowerCase();
  if (msg.contains('already open') || msg.contains('not initialized')) {
    return false;
  }
  return error is HiveError ||
      error is FormatException ||
      error is RangeError ||
      msg.contains('typeid') ||
      msg.contains('checksum') ||
      msg.contains('corrupt') ||
      msg.contains('cannot read');
}

/// Opens [boxName], deleting the corrupt file and recreating a fresh box if
/// [Hive.openBox] fails due to corruption (e.g. from an unknown type ID or truncated file).
Future<Box<Map>> openPlaybackMemoryBox({
  String boxName = HivePlaybackMemory.boxName,
  String? path,
}) async {
  try {
    return await Hive.openBox<Map>(boxName, path: path);
  } catch (e) {
    if (!isBoxCorruptionError(e)) {
      rethrow;
    }
    debugPrint(
      '[PlaybackMemory] Failed to open box "$boxName" due to corruption ($e). '
      'Deleting corrupt box and recreating...',
    );
    try {
      await Hive.deleteBoxFromDisk(boxName, path: path);
      return await Hive.openBox<Map>(boxName, path: path);
    } catch (retryError) {
      debugPrint(
        '[PlaybackMemory] Recreating box "$boxName" failed: $retryError',
      );
      rethrow;
    }
  }
}

/// The persistent box backing [playbackMemoryProvider].
final playbackMemoryBoxProvider = FutureProvider<Box<Map>>((ref) async {
  return openPlaybackMemoryBox();
});

/// Opened once per app. A failed open uses empty in-memory advisory state,
/// never becoming a playback error.
final playbackMemoryProvider = FutureProvider<PlaybackMemory>((ref) async {
  try {
    final box = await ref.watch(playbackMemoryBoxProvider.future);
    return HivePlaybackMemory(box);
  } catch (e) {
    debugPrint('[PlaybackMemory] Could not open memory box: $e');
    return InMemoryPlaybackMemory();
  }
});
