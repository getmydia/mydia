/// Web implementation: the browser paints the cues.
///
/// See `subtitle_cues.dart` for why Flutter cannot.
library;

import 'package:media_kit/media_kit.dart';
// The `WebPlayer` media_kit exports publicly is a conditional export, and the
// analyzer resolves it to the stub, which owns no element. This file only ever
// compiles for the web, where that export is this very library, so naming it
// directly is the same class at runtime and a type the analyzer can see
// through. It breaks loudly if media_kit moves the file.
// ignore: implementation_imports
import 'package:media_kit/src/player/web/player/real.dart' as media_kit_web;
import 'package:web/web.dart' as web;

/// The element media_kit created for this player, or null when there is none
/// to reach (a native backend, or a player already disposed).
///
/// `WebPlayer` is part of media_kit's public surface and holds its own
/// element, so this asks the player rather than hunting the document for a
/// `<video>`: a cast session or a second screen can have more than one, and
/// picking the wrong one would silently subtitle the wrong video.
web.HTMLVideoElement? _elementOf(Player player) {
  final platform = player.platform;
  if (platform is! media_kit_web.WebPlayer) return null;
  return platform.element;
}

void showSubtitleCues(Player player, {required bool enabled}) {
  final element = _elementOf(player);
  if (element == null) return;
  applyCueVisibility(element, enabled: enabled);
}

/// The DOM half of [showSubtitleCues], against an element rather than a
/// player, so it can be exercised on a hand-built `<video>` in a browser test.
void applyCueVisibility(web.HTMLVideoElement element, {required bool enabled}) {
  final tracks = element.textTracks;

  // Every pick appends another `<track>`, including a re-pick of one already
  // added, so the newest is the last and everything before it is spent. They
  // are disabled rather than removed: media_kit owns those child elements and
  // revokes their blob URLs at dispose, and a disabled track drops its cues
  // until something shows it again.
  for (var i = 0; i < tracks.length; i++) {
    tracks[i].mode = 'disabled';
  }

  if (!enabled || tracks.length == 0) return;

  final track = tracks[tracks.length - 1];

  // media_kit attaches its own `cuechange` handler to feed `SubtitleView`,
  // and that handler throws on every cue (see `subtitle_cues.dart`). Dropping
  // it stops a `NoSuchMethodError` per cue from reaching the console for the
  // length of the film. Nothing else reads the stream it was feeding.
  track.oncuechange = null;

  track.mode = 'showing';
}
