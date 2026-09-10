import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';

import 'playback_memory.dart';

/// The persistent box backing [playbackMemoryProvider].
final playbackMemoryBoxProvider = FutureProvider<Box<Map>>((ref) async {
  return Hive.openBox<Map>(HivePlaybackMemory.boxName);
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
