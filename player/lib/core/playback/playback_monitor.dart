/// Turns media_kit's streams into one `HealthSample` a second.
library;

import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'frame_stats_sampler.dart';
import 'health_sample.dart';

/// The streams the monitor reads, so a test can drive it without a `Player`.
class PlayerSignals {
  const PlayerSignals({
    required this.position,
    required this.buffer,
    required this.buffering,
    required this.playing,
    required this.error,
  });

  factory PlayerSignals.of(Player player) => PlayerSignals(
        position: player.stream.position,
        buffer: player.stream.buffer,
        buffering: player.stream.buffering,
        playing: player.stream.playing,
        error: player.stream.error,
      );

  final Stream<Duration> position;

  /// media_kit's buffered position: `demuxer-cache-time` on native, the last
  /// `buffered` range end on web. Absolute, not relative to position.
  final Stream<Duration> buffer;
  final Stream<bool> buffering;
  final Stream<bool> playing;
  final Stream<String> error;
}

class PlaybackMonitor {
  PlaybackMonitor({
    required PlayerSignals signals,
    required FrameStatsSampler sampler,
    this.interval = const Duration(seconds: 1),
  })  : _signals = signals,
        _sampler = sampler;

  final PlayerSignals _signals;
  final FrameStatsSampler _sampler;
  final Duration interval;

  final _samples = StreamController<HealthSample>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  Timer? _timer;

  Duration _position = Duration.zero;
  Duration _buffer = Duration.zero;
  bool _buffering = false;
  bool _playing = false;
  bool _fault = false;
  int? _lastDropped;
  int _ticks = 0;
  bool _sampling = false;
  bool _disposed = false;
  int _generation = 0;

  Stream<HealthSample> get samples => _samples.stream;

  void start() {
    if (_timer != null || _disposed) return;
    _subscriptions.addAll([
      _signals.position.listen((p) => _position = p),
      _signals.buffer.listen((b) => _buffer = b),
      _signals.buffering.listen((b) => _buffering = b),
      _signals.playing.listen((p) => _playing = p),
      _signals.error.listen((_) => _fault = true),
    ]);
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  /// Starts the clock and the dropped-frame baseline over, for a new source.
  void reset() {
    _generation++;
    _ticks = 0;
    _lastDropped = null;
    _fault = false;
  }

  Future<void> _tick() async {
    // A slow property read must not stack samples.
    if (_sampling || _disposed) return;
    _sampling = true;
    final generation = _generation;
    try {
      final stats = await _sampler.sample();
      // A source reset or disposal during a read makes that reading stale.
      if (_disposed || generation != _generation) return;

      final previous = _lastDropped;
      final dropped = stats == null || previous == null
          ? null
          : stats.droppedFrames - previous;
      _lastDropped = stats?.droppedFrames;
      _ticks++;

      final ahead = _buffer - _position;
      final sample = HealthSample(
        at: interval * _ticks,
        position: _position,
        bufferedAhead: ahead.isNegative ? Duration.zero : ahead,
        buffering: _buffering,
        playing: _playing,
        droppedFrames: dropped,
        throughputKbps: stats?.throughputKbps,
        fault: _fault,
      );
      _fault = false;
      if (!_samples.isClosed) _samples.add(sample);
    } finally {
      _sampling = false;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _timer = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _samples.close();
  }
}
