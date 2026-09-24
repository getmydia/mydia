/// Where mpv draws a bitmap subtitle track while the playback chrome is up.
///
/// Text tracks are drawn by media_kit's `SubtitleView` and lifted through its
/// padding. Bitmap tracks (PGS, VobSub, DVB, XSUB) are drawn by mpv inside
/// the picture (see `subtitle_render.dart`), so the same lift has to reach
/// mpv as `sub-pos`, a percentage of the picture's height.
library;

import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:media_kit/media_kit.dart';

import 'subtitle_position_stub.dart'
    if (dart.library.io) 'subtitle_position_native.dart' as platform;

/// media_kit's default `SubtitleView` bottom padding: where subtitles sit
/// with no chrome to clear.
const double kSubtitleRestPadding = 24;

/// The mpv `sub-pos` that keeps a bitmap subtitle clear of the bottom [lift]
/// logical pixels of a `Video` box of size [box].
///
/// `Video` fits the picture with `BoxFit.contain`, so a picture wider than
/// the box leaves a bar below it. A bitmap subtitle sits inside the picture,
/// so that bar already counts toward the clearance and only the remainder
/// moves it. Without [videoWidth] and [videoHeight] the picture is taken to
/// fill the box.
double subPosForLift({
  required double lift,
  required Size box,
  int? videoWidth,
  int? videoHeight,
}) {
  if (lift <= kSubtitleRestPadding || box.height <= 0) return 100;

  var displayed = box.height;
  if (videoWidth != null &&
      videoHeight != null &&
      videoWidth > 0 &&
      videoHeight > 0) {
    displayed = math.min(box.height, box.width * videoHeight / videoWidth);
  }
  if (displayed <= 0) return 100;

  final bar = (box.height - displayed) / 2;
  final shift = math.max(0.0, lift - bar);
  return (100 - 100 * shift / displayed).clamp(0.0, 100.0);
}

/// Sets mpv's `sub-pos` to [subPos]. A no-op on web, where mpv never draws.
Future<void> applySubtitlePosition(Player player, double subPos) =>
    platform.applySubtitlePosition(player, subPos);
