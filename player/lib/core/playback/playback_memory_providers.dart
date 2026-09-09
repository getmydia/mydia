import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';

import 'playback_memory.dart';

/// Opened once per app. A failed open is treated as "no memory" by the
/// player screen, never as a playback error.
final playbackMemoryProvider = FutureProvider<PlaybackMemory>((ref) async {
  final box = await Hive.openBox<Map>(HivePlaybackMemory.boxName);
  return HivePlaybackMemory(box);
});
