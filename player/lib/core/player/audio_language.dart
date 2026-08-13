import 'package:media_kit/media_kit.dart';

import 'audio_language_stub.dart'
    if (dart.library.io) 'audio_language_native.dart' as platform;

/// Tells the underlying player which audio language to open a file on.
///
/// mpv runs with `alang` unset unless someone sets it, and then falls through
/// to whatever the container flagged `default`. On a dual-language release
/// that flag is routinely on the dub, which is how a show with English
/// original audio could open in Russian.
///
/// The ordered list comes from the server
/// (`streamingCandidates.metadata.preferredAudioLanguages`) rather than being
/// assembled here. Resolving it needs the item's original language from TMDB
/// metadata and the operator's `streaming.audio_language` config, neither of
/// which the client holds, and keeping one implementation means direct play
/// and the transcode path cannot disagree about which track is right.
///
/// Split across a conditional import because the mpv property API only exists
/// on native: media_kit's web `NativePlayer` is a stub class with no
/// `setProperty` at all, so a direct call would not compile for web.
class AudioLanguage {
  /// Applies [languages] to [player], most preferred first.
  ///
  /// Must be called *before* `player.open`. mpv chooses its tracks while
  /// loading the file, so a preference set afterwards does not retroactively
  /// reselect, and the viewer would still get the first few seconds of the
  /// wrong language even if a later switch corrected it.
  ///
  /// An empty [languages] is a deliberate no-op meaning "no opinion": either
  /// the operator set `prefer_default_audio_track` and wants the container's
  /// flag to win, or the server predates the field. Forcing a guess in that
  /// case would override a choice someone made on purpose.
  ///
  /// Never throws. Losing the preference costs this playback its language;
  /// letting the failure escape would cost the playback itself.
  static Future<void> apply(Player player, List<String> languages) async {
    if (languages.isEmpty) return;
    await platform.setAudioLanguage(player, languages);
  }
}
