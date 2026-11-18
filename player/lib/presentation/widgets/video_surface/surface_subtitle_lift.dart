import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:media_kit/media_kit.dart';

import '../../../core/player/subtitle_position.dart';
import '../../../core/player/video_scaling.dart';
import '../video_controls/chrome_subtitle_lift.dart';
import 'mydia_subtitle_view.dart';

/// [SubtitleLift] for the native video surface, which has no `VideoState`.
///
/// Mirrors `VideoStateSubtitleLift`: text goes through the
/// [MydiaSubtitleView] padding, bitmap tracks go to mpv as `sub-pos`. Both
/// are written every time, whichever renderer is idle ignores its value.
class SurfaceSubtitleLift implements SubtitleLift {
  SurfaceSubtitleLift({
    required this.player,
    required this.subtitles,
    required this.box,
    this.scaling = VideoScaling.fit,
    Future<void> Function(Player player, double subPos) applyPosition =
        applySubtitlePosition,
  }) : _applyPosition = applyPosition;

  final Player player;
  final MydiaSubtitleViewController subtitles;

  /// The size of the box subtitles are drawn in, read at apply time.
  final Size Function() box;

  /// The picture's scaling. Fill (`panscan=1`) covers the box, so no
  /// letterbox bar absorbs part of the lift.
  final VideoScaling scaling;

  final Future<void> Function(Player player, double subPos) _applyPosition;

  // `PlaybackChrome` builds a fresh lift on every rebuild; equality on what
  // it drives lets `ChromeSubtitleLift` see "the same lift". Scaling is part
  // of it: the same lift in pixels is a different `sub-pos` under fill, so
  // a change of scaling must reach mpv again.
  @override
  bool operator ==(Object other) =>
      other is SurfaceSubtitleLift &&
      identical(other.player, player) &&
      identical(other.subtitles, subtitles) &&
      other.scaling == scaling;

  @override
  int get hashCode => Object.hash(
      identityHashCode(player), identityHashCode(subtitles), scaling);

  @override
  void apply(double bottom, {required Duration duration}) {
    // At rest the text goes back to the configuration's own padding, which
    // can change while no lift is up.
    if (bottom <= kSubtitleRestPadding) {
      subtitles.resetPadding(duration: duration);
    } else {
      subtitles.setPadding(
        EdgeInsets.fromLTRB(16, 0, 16, bottom),
        duration: duration,
      );
    }
    // Without the picture's size, `subPosForLift` takes it to fill the box,
    // which is what fill does.
    final fitted = scaling == VideoScaling.fit;
    unawaited(_applyPosition(
      player,
      subPosForLift(
        lift: bottom,
        box: box(),
        videoWidth: fitted ? player.state.width : null,
        videoHeight: fitted ? player.state.height : null,
      ),
    ));
  }
}
