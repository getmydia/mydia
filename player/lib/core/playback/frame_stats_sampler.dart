/// Reads dropped-frame and throughput counters from whatever engine is
/// playing. Split across a conditional import for the same reason as
/// `audio_language.dart`: mpv's property API only exists on native, and the
/// video element only on web.
library;

import 'package:media_kit/media_kit.dart';

import 'frame_stats_sampler_stub.dart'
    if (dart.library.io) 'frame_stats_sampler_native.dart'
    if (dart.library.js_interop) 'frame_stats_sampler_web.dart' as platform;
import 'health_sample.dart';

abstract class FrameStatsSampler {
  /// Null means "no reading this second", never zero.
  Future<FrameStats?> sample();
}

class NoFrameStatsSampler implements FrameStatsSampler {
  const NoFrameStatsSampler();

  @override
  Future<FrameStats?> sample() async => null;
}

/// The sampler for [player]'s engine, or [NoFrameStatsSampler] when the
/// engine is not one this build knows how to read.
///
/// [hdr] adds mpv's output transfer and color matrix to each reading, for
/// the stats panel's HDR row. Off for the playback monitor, which reads
/// only the counters every second of every playback.
FrameStatsSampler frameStatsSamplerFor(Player player, {bool hdr = false}) =>
    platform.samplerFor(player, hdr: hdr);
