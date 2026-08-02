import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/player/stream_timeline.dart';
import 'playback_chrome.dart';

/// Builder for media_kit's `Video(controls: ...)` parameter.
///
/// All chrome now lives in [PlaybackChrome]; this file is only the adapter
/// between media_kit's builder signature and that widget.
Widget Function(VideoState) customVideoControlsBuilderWithCallback({
  required StreamTimeline timeline,
  required Future<void> Function(Duration realTarget) onSeekToReal,
  String? title,
  VoidCallback? onBack,
  Widget? castAction,
  VoidCallback? onAudioTap,
  VoidCallback? onSubtitleTap,
  VoidCallback? onQualityTap,
  VoidCallback? onFullscreenTap,
  VoidCallback? onPreviousEpisode,
  VoidCallback? onNextEpisode,
  bool isFullscreen = false,
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
        onAudioTap: onAudioTap,
        onSubtitleTap: onSubtitleTap,
        onQualityTap: onQualityTap,
        onFullscreenTap: onFullscreenTap,
        onPreviousEpisode: onPreviousEpisode,
        onNextEpisode: onNextEpisode,
        isFullscreen: isFullscreen,
        audioTrackCount: audioTrackCount,
        subtitleTrackCount: subtitleTrackCount,
        selectedAudioLabel: selectedAudioLabel,
        selectedSubtitleLabel: selectedSubtitleLabel,
        selectedQualityLabel: selectedQualityLabel,
      );
}
