/// Native `track-list` reads for `subtitleStreamIndices`.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:media_kit/media_kit.dart';

import 'mpv_track_entry.dart';

/// See `subtitle_stream_index.dart`.
///
/// The `is! NativePlayer` guard is not redundant with the conditional
/// import, for the same reason `subtitle_delay_native.dart` gives.
Future<Map<String, int>> subtitleStreamIndices(Player player) async {
  final platform = player.platform;
  if (platform is! NativePlayer) return const {};

  try {
    final count =
        int.tryParse(await platform.getProperty('track-list/count')) ?? 0;
    final indices = <String, int>{};
    for (var i = 0; i < count; i++) {
      final entry = subtitleStreamIndexEntry(
        type: await platform.getProperty('track-list/$i/type'),
        id: await platform.getProperty('track-list/$i/id'),
        ffIndex: await platform.getProperty('track-list/$i/ff-index'),
        external: await platform.getProperty('track-list/$i/external'),
      );
      if (entry != null) indices[entry.key] = entry.value;
    }
    return indices;
  } catch (e) {
    debugPrint('[SubtitleStreamIndex] Could not read track-list: $e');
    return const {};
  }
}
