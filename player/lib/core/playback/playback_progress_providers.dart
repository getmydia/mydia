import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';

import 'playback_progress_store.dart';

/// Keep-alive: the store is opened once and read from the player screen on
/// every playback start, including offline, where nothing else is available
/// to rebuild it.
final playbackProgressStoreProvider =
    FutureProvider<PlaybackProgressStore>((ref) async {
  final box = await Hive.openBox<Map>(HivePlaybackProgressStore.boxName);
  return HivePlaybackProgressStore(box);
});
