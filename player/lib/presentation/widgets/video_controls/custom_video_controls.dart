import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/player/stream_timeline.dart';
import 'playback_chrome.dart';

/// Builder for media_kit's `Video(controls: ...)` parameter.
///
/// All chrome now lives in [PlaybackChrome]; this file is only the adapter
/// between media_kit's builder signature and that widget.
///
/// [castAction] and [onCastTap] are `required` despite being nullable, which
/// the other optional chrome parameters are not. Casting was invisible for the
/// whole of playback once before: the refactor that introduced [PlaybackChrome]
/// deleted the old top bar — cast button and all — and left the replacement's
/// cast slot unfilled, so the affordance survived only in the loading and
/// error states nobody demos. Requiring them turns "forgot the cast
/// affordance" from something you have to notice into something that does not
/// compile.
Widget Function(VideoState) customVideoControlsBuilderWithCallback({
  required StreamTimeline timeline,
  required Future<void> Function(Duration realTarget) onSeekToReal,
  required Widget? castAction,
  required VoidCallback? onCastTap,
  String? title,
  VoidCallback? onBack,
  VoidCallback? onAudioTap,
  VoidCallback? onSubtitleTap,
  VoidCallback? onQualityTap,
  VoidCallback? onFullscreenTap,
  VoidCallback? onAlwaysOnTopTap,
  VoidCallback? onPreviousEpisode,
  VoidCallback? onNextEpisode,
  VoidCallback? onActivity,
  bool isFullscreen = false,
  bool isAlwaysOnTop = false,
  int audioTrackCount = 0,
  int subtitleTrackCount = 0,
  String? selectedAudioLabel,
  String? selectedSubtitleLabel,
  String? selectedQualityLabel,
}) {
  return (VideoState state) => PlaybackChrome(
        player: state.widget.controller.player,
        timeline: timeline,
        onSeekToReal: onSeekToReal,
        title: title,
        onBack: onBack,
        castAction: castAction,
        onCastTap: onCastTap,
        onAudioTap: onAudioTap,
        onSubtitleTap: onSubtitleTap,
        onQualityTap: onQualityTap,
        onFullscreenTap: onFullscreenTap,
        onAlwaysOnTopTap: onAlwaysOnTopTap,
        onPreviousEpisode: onPreviousEpisode,
        onNextEpisode: onNextEpisode,
        onActivity: onActivity,
        isFullscreen: isFullscreen,
        isAlwaysOnTop: isAlwaysOnTop,
        audioTrackCount: audioTrackCount,
        subtitleTrackCount: subtitleTrackCount,
        selectedAudioLabel: selectedAudioLabel,
        selectedSubtitleLabel: selectedSubtitleLabel,
        selectedQualityLabel: selectedQualityLabel,
      );
}
