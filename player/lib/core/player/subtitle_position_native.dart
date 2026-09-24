/// Native bitmap subtitle position, via mpv's `sub-pos` property.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:media_kit/media_kit.dart';

/// Writes [subPos] as a whole percentage. Older mpv builds parse `sub-pos`
/// as an integer, and one percent of a 1080p picture is under 11px.
///
/// The `is! NativePlayer` guard matches `subtitle_delay_native.dart`:
/// `player.platform` is nullable until the player finishes initialising.
Future<void> applySubtitlePosition(Player player, double subPos) async {
  final platform = player.platform;
  if (platform is! NativePlayer) return;

  try {
    await platform.setProperty(
      'sub-pos',
      subPos.round().clamp(0, 100).toString(),
    );
  } catch (e) {
    // A failed write leaves a bitmap subtitle under the chrome, as before
    // this existed. Not worth failing playback over.
    debugPrint('[SubtitlePosition] Could not set sub-pos=$subPos: $e');
  }
}
