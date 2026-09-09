/// mpv counters through media_kit's `NativePlayer.getProperty`.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:media_kit/media_kit.dart';

import 'frame_stats_sampler.dart';
import 'health_sample.dart';

FrameStatsSampler samplerFor(Player player) {
  final platform = player.platform;
  if (platform is! NativePlayer) return const NoFrameStatsSampler();
  return NativeFrameStatsSampler(platform);
}

class NativeFrameStatsSampler implements FrameStatsSampler {
  NativeFrameStatsSampler(this._platform);

  final NativePlayer _platform;

  @override
  Future<FrameStats?> sample() async {
    try {
      // `frame-drop-count` is frames the VO dropped; `decoder-frame-drop-count`
      // is frames the decoder skipped. Either means decode is behind.
      final vo = int.tryParse(await _platform.getProperty('frame-drop-count'));
      final decoder = int.tryParse(
        await _platform.getProperty('decoder-frame-drop-count'),
      );
      if (vo == null && decoder == null) return null;
      // `cache-speed` is bytes per second of network read.
      final speed = double.tryParse(await _platform.getProperty('cache-speed'));
      return FrameStats(
        droppedFrames: (vo ?? 0) + (decoder ?? 0),
        throughputKbps: speed == null ? null : (speed * 8 / 1000).round(),
      );
    } catch (e) {
      debugPrint('[FrameStats] mpv property read failed: $e');
      return null;
    }
  }
}
