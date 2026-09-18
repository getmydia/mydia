/// One [StatsSample] a second, for the stats panel.
///
/// Deliberately not `PlaybackMonitor`. That class is armed only for a
/// server-backed, non-cast source, because arming it more widely would
/// change what `AdaptationPolicy` observes; its dropped-frame figure is a
/// delta whose baseline resets per verification generation; and its
/// lifetime is a verification window rather than a playback session. What
/// is worth reusing sits one layer down: [FrameStatsSampler] already
/// returns cumulative counters, already has native, web and stub
/// implementations, and already answers null on a failed property read.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../frame_stats_sampler.dart';
import '../health_sample.dart' show FrameStats;
import '../playback_monitor.dart' show PlayerSignals;
import 'playback_stats.dart';

class PlaybackStatsCollector {
  PlaybackStatsCollector({
    required PlayerSignals signals,
    required FrameStatsSampler sampler,
    this.interval = const Duration(seconds: 1),
  })  : _signals = signals,
        _sampler = sampler;

  final PlayerSignals _signals;
  final FrameStatsSampler _sampler;
  final Duration interval;

  /// Points behind the sparkline, which is a 60-second window.
  static const int historyLength = 60;

  /// How long the last good throughput reading stays on screen once the
  /// engine stops answering. A frozen number reads as current, so after
  /// this the row drops out instead.
  static const Duration throughputStaleAfter = Duration(seconds: 5);

  final _samples = ValueNotifier<StatsSample?>(null);
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _history = <StatsPoint>[];

  Timer? _timer;
  Duration _position = Duration.zero;
  Duration _buffer = Duration.zero;
  int? _lastTotal;
  int? _lastThroughput;
  int _unreadableTicks = 0;
  bool _sampling = false;
  bool _disposed = false;
  int _generation = 0;

  ValueListenable<StatsSample?> get samples => _samples;

  void start() {
    if (_timer != null || _disposed) return;
    _subscriptions.addAll([
      _signals.position.listen((p) => _position = p),
      _signals.buffer.listen((b) => _buffer = b),
    ]);
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  /// Starts over for a new source: a fresh dropped-frame baseline, an
  /// empty history, and no sample until the next tick. Without this, the
  /// first reading of a new source diffs against the previous source's
  /// cumulative count and reports a spike that never happened.
  void rebind() {
    _generation++;
    _history.clear();
    _lastTotal = null;
    _lastThroughput = null;
    _unreadableTicks = 0;
    _samples.value = null;
  }

  Future<void> _tick() async {
    if (_disposed || _sampling) return;
    _sampling = true;
    final generation = _generation;
    try {
      final stats = await _sampler.sample();
      // A rebind or disposal during the read makes this reading stale.
      if (_disposed || generation != _generation) return;

      final previous = _lastTotal;
      final total = stats?.droppedFrames;
      final delta = total == null || previous == null ? null : total - previous;
      if (total != null) _lastTotal = total;

      final throughput = _updateThroughput(stats);

      final ahead = _buffer - _position;
      final bufferedAhead = ahead.isNegative ? Duration.zero : ahead;

      _history.add(
        StatsPoint(
          bufferedMs: bufferedAhead.inMilliseconds,
          throughputKbps: throughput,
        ),
      );
      if (_history.length > historyLength) _history.removeAt(0);

      _samples.value = StatsSample(
        bufferedAhead: bufferedAhead,
        position: _position,
        droppedFrames: delta,
        droppedFramesTotal: _lastTotal,
        throughputKbps: throughput,
        history: List.unmodifiable(_history),
      );
    } finally {
      _sampling = false;
    }
  }

  /// The engine's reading when it has one, the previous reading while it is
  /// inside [throughputStaleAfter], and null after that.
  ///
  /// Advances the staleness counter as a side effect and must be called
  /// exactly once per tick.
  int? _updateThroughput(FrameStats? stats) {
    final reading = stats?.throughputKbps;
    if (reading != null) {
      _lastThroughput = reading;
      _unreadableTicks = 0;
      return reading;
    }
    _unreadableTicks++;
    final grace =
        throughputStaleAfter.inMicroseconds ~/ interval.inMicroseconds;
    if (_unreadableTicks > grace) {
      _lastThroughput = null;
      return null;
    }
    return _lastThroughput;
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
    _samples.dispose();
  }
}
