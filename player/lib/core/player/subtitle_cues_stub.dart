/// Native implementation: nothing to hand over.
///
/// mpv draws a bitmap track and `SubtitleView` draws a text one, both from
/// `Player.stream.subtitle`, which works everywhere except the browser. See
/// `subtitle_cues.dart`.
library;

import 'package:media_kit/media_kit.dart';

void showSubtitleCues(Player player, {required bool enabled}) {}
