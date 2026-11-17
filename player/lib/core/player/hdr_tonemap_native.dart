/// Native half of `hdr_tonemap.dart`.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:media_kit/media_kit.dart';

import 'mac_video_output.dart';
import 'video_output_config.dart';

Future<void> applySdrTonemap(Player player,
    {required VideoOutputPath path}) async {
  final platform = player.platform;
  if (platform is! NativePlayer) return;

  for (final entry in sdrTonemapMpvOptionsFor(path).entries) {
    try {
      await platform.setProperty(entry.key, entry.value);
    } catch (e) {
      // A failed set leaves mpv's own default for that option, which is the
      // behaviour before this was wired at all.
      debugPrint('[Tonemap] Could not set ${entry.key}=${entry.value}: $e');
    }
  }
}
