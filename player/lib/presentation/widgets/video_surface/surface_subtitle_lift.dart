import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:media_kit/media_kit.dart';

import '../../../core/player/subtitle_position.dart';
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
    Future<void> Function(Player player, double subPos) applyPosition =
        applySubtitlePosition,
  }) : _applyPosition = applyPosition;

  final Player player;
  final MydiaSubtitleViewController subtitles;

  /// The size of the box subtitles are drawn in, read at apply time.
  final Size Function() box;

  final Future<void> Function(Player player, double subPos) _applyPosition;

  // `PlaybackChrome` builds a fresh lift on every rebuild; equality on what
  // it drives lets `ChromeSubtitleLift` see "the same lift".
  @override
  bool operator ==(Object other) =>
      other is SurfaceSubtitleLift &&
      identical(other.player, player) &&
      identical(other.subtitles, subtitles);

  @override
  int get hashCode =>
      Object.hash(identityHashCode(player), identityHashCode(subtitles));

  @override
  void apply(double bottom, {required Duration duration}) {
    subtitles.setPadding(
      EdgeInsets.fromLTRB(16, 0, 16, bottom),
      duration: duration,
    );
    unawaited(_applyPosition(
      player,
      subPosForLift(
        lift: bottom,
        box: box(),
        videoWidth: player.state.width,
        videoHeight: player.state.height,
      ),
    ));
  }
}
