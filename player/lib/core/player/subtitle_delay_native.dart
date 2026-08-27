/// Native subtitle delay adjustment, via mpv's `sub-delay` property.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:media_kit/media_kit.dart';

/// Sets mpv's `sub-delay` to [delayMs], converted to the decimal-seconds
/// string mpv expects.
///
/// The `is! NativePlayer` guard is not redundant with the conditional
/// import. A native build can still be handed a player whose platform is
/// something else, and `player.platform` is nullable until the player
/// finishes initialising.
Future<void> applySubtitleDelay(Player player, int delayMs) async {
  final platform = player.platform;
  if (platform is! NativePlayer) return;

  try {
    await platform.setProperty(
      'sub-delay',
      (delayMs / 1000).toStringAsFixed(3),
    );
  } catch (e) {
    // A failed delay costs this playback its timing correction and nothing
    // more; letting the failure escape would cost the playback itself.
    debugPrint('[SubtitleDelay] Could not set sub-delay=$delayMs ms: $e');
  }
}
