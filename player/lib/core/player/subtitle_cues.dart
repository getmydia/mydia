/// Who paints subtitle cues in the browser.
///
/// On web media_kit hands a picked track to the `<video>` element as a
/// `<track>` child, leaves it `hidden`, and feeds Flutter's `SubtitleView`
/// from its own `cuechange` handler. That handler cannot work: it reads
/// `activeCues.dartify` without calling it (`media_kit/lib/src/player/web/
/// player/real.dart`, marked "UNTESTED" by its author), so every cue change
/// throws `NoSuchMethodError` into media_kit's catch, `Player.stream.subtitle`
/// never emits, and the viewer sees nothing at all. Measured 2026-09-19: a
/// track attaches, all 1080 of its cues parse, one is active at the right
/// moment, and the screen stays blank.
///
/// So let the browser draw them, which is the one renderer here that works:
/// [showSubtitleCues] flips the track media_kit just added to `showing`.
/// Nothing is styled from Dart, which costs nothing today because the player
/// exposes no subtitle appearance settings to honour.
///
/// A no-op off the web, where mpv or `SubtitleView` already draws. See
/// `subtitle_render.dart` for that side of the split.
library;

import 'package:media_kit/media_kit.dart';

import 'subtitle_cues_stub.dart'
    if (dart.library.js_interop) 'subtitle_cues_web.dart' as platform;

/// Draws the cues of the track most recently handed to [player], or stops
/// drawing any when [enabled] is false.
///
/// Call after every subtitle selection has actually taken effect, "Off"
/// included. media_kit does nothing at all for `SubtitleTrack.no()` on web,
/// so without the disabling half a viewer cannot turn subtitles back off.
void showSubtitleCues(Player player, {required bool enabled}) =>
    platform.showSubtitleCues(player, enabled: enabled);
