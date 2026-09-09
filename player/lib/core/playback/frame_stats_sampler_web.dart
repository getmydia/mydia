/// `HTMLVideoElement.getVideoPlaybackQuality()` through media_kit's public
/// `WebPlayer.element`, reached the way `fullscreen_backend_web.dart` does.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:media_kit/media_kit.dart';
import 'package:web/web.dart' as web;

import 'frame_stats_sampler.dart';
import 'health_sample.dart';

FrameStatsSampler samplerFor(Player player) {
  final platform = player.platform;
  if (platform is! WebPlayer) return const NoFrameStatsSampler();
  // `WebPlayer.element` exists on the web `real.dart`; `dart analyze`
  // resolves the conditional export to `stub.dart`, which has no `element`,
  // so a static read fails analysis. Same bridge as the fullscreen backend.
  final video = (platform as dynamic).element as web.HTMLVideoElement;
  return WebFrameStatsSampler(video);
}

class WebFrameStatsSampler implements FrameStatsSampler {
  WebFrameStatsSampler(this._video);

  final web.HTMLVideoElement _video;

  @override
  Future<FrameStats?> sample() async {
    try {
      final quality = _video.getVideoPlaybackQuality();
      return FrameStats(droppedFrames: quality.droppedVideoFrames);
    } catch (e) {
      debugPrint('[FrameStats] getVideoPlaybackQuality failed: $e');
      return null;
    }
  }
}
