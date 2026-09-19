/// Native half of `subtitle_render.dart`.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:media_kit/media_kit.dart';

import 'subtitle_render.dart';

/// mpv's own record of the active subtitle track's codec. media_kit's
/// `stream.track` cannot stand in for it: media_kit 1.2.6 observes neither
/// `sid` nor the codec, records a `sub-add`ed track exactly as the app
/// handed it over (with no codec), and never hears about a default track
/// mpv selects on its own when a file opens. mpv publishes this for all
/// three. With no track selected the property is unavailable and media_kit
/// calls nothing, which leaves visibility where it was; nothing is drawn
/// either way.
const _activeCodec = 'current-tracks/sub/codec';

Future<void> watchSubtitleRendering(Player player) async {
  try {
    // Inside the try, unlike `subtitle_delay_native.dart`: this runs
    // unawaited, so a throw here would surface as an unhandled error.
    final platform = player.platform;
    if (platform is! NativePlayer) return;

    await platform.observeProperty(_activeCodec, (codec) async {
      await platform.setProperty(
        'sub-visibility',
        mpvDrawsSubtitle(codec) ? 'yes' : 'no',
      );
    });
  } catch (e) {
    // Losing this costs bitmap tracks their picture and nothing else.
    debugPrint('[SubtitleRender] Could not watch $_activeCodec: $e');
  }
}
