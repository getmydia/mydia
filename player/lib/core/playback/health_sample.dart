/// One second of playback health, as the policy sees it.
library;

class HealthSample {
  const HealthSample({
    required this.at,
    required this.position,
    required this.bufferedAhead,
    required this.buffering,
    required this.playing,
    this.droppedFrames,
    this.throughputKbps,
    this.fault = false,
  });

  /// Time since the monitor started or was last reset.
  final Duration at;
  final Duration position;

  /// How far past [position] the player has buffered. Never negative.
  final Duration bufferedAhead;
  final bool buffering;
  final bool playing;

  /// Frames dropped since the previous sample. Null when unknown, which the
  /// policy treats as unknown and never as zero.
  final int? droppedFrames;

  /// Measured delivery throughput. Null off native, or when mpv has none.
  final int? throughputKbps;

  /// An error event arrived since the previous sample.
  final bool fault;

  @override
  String toString() => 'HealthSample(at: ${at.inSeconds}s, '
      'pos: ${position.inSeconds}s, ahead: ${bufferedAhead.inSeconds}s, '
      'buffering: $buffering, playing: $playing, dropped: $droppedFrames, '
      'kbps: $throughputKbps, fault: $fault)';
}

/// Cumulative counters read from the engine.
class FrameStats {
  const FrameStats({required this.droppedFrames, this.throughputKbps});

  /// Total frames dropped since the source opened.
  final int droppedFrames;
  final int? throughputKbps;
}
