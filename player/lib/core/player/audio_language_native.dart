/// Native audio-language selection, via mpv's `alang` property.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:media_kit/media_kit.dart';

/// Sets mpv's `alang` to [languages], most preferred first.
///
/// mpv takes a comma-separated list and scores each audio track against it,
/// so passing the whole list at once (rather than one code) is what makes the
/// fallback work: `jpn,eng` plays Japanese where it exists and English
/// otherwise, with the container's `default` flag deciding only when neither
/// is present.
///
/// The `is NativePlayer` guard is not redundant with the conditional import.
/// A native build can still be handed a player whose platform is something
/// else, and `player.platform` is nullable until the player finishes
/// initialising.
Future<void> setAudioLanguage(Player player, List<String> languages) async {
  final platform = player.platform;
  if (platform is! NativePlayer) return;

  try {
    await platform.setProperty('alang', languages.join(','));
  } catch (e) {
    // A failed property set costs this playback its language preference and
    // nothing more: mpv falls back to the container's own flag, which is the
    // behaviour that existed before this was wired at all.
    debugPrint('[AudioLanguage] Could not set alang=$languages: $e');
  }
}
