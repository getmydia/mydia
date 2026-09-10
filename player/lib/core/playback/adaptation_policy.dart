/// Decides, from health samples, when a source has to be replaced.
///
/// Pure state machine over `HealthSample`s. In this phase it emits only
/// `FallbackToTranscode`, for direct play and copy sources. Rung switching
/// arrives with the Auto rung.
library;

import 'adaptation_thresholds.dart';
import 'health_sample.dart';
import 'playback_memory.dart';

enum SourceKind { direct, copy, transcode }

sealed class AdaptationAction {
  const AdaptationAction();
}

class NoAction extends AdaptationAction {
  const NoAction();
}

class FallbackToTranscode extends AdaptationAction {
  const FallbackToTranscode({required this.reason, this.throughputKbps});

  final FailureReason reason;

  /// The last throughput the monitor measured, for choosing the fallback rung.
  final int? throughputKbps;
}

class AdaptationPolicy {
  AdaptationPolicy({
    required this.source,
    this.thresholds = const AdaptationThresholds(),
  });

  final SourceKind source;
  final AdaptationThresholds thresholds;

  Duration _playingTime = Duration.zero;
  bool _advanced = false;
  Duration? _firstPosition;
  bool _inStall = false;
  final List<Duration> _stalls = [];
  Duration? _previousAhead;
  int _drainRun = 0;
  final List<int> _recentDrops = [];
  int? _lastThroughput;
  bool _done = false;

  bool get done => _done;

  bool get verifying => !_done && _playingTime < thresholds.verificationWindow;

  AdaptationAction observe(HealthSample sample) {
    if (_done) return const NoAction();
    final wasVerifying = verifying;
    _record(sample);
    if (source == SourceKind.transcode) return const NoAction();

    final action = wasVerifying ? _verify(sample) : _later(sample);
    if (wasVerifying && !verifying) _stalls.clear();
    if (action is! NoAction) _done = true;
    return action;
  }

  void _record(HealthSample sample) {
    if (sample.throughputKbps != null) _lastThroughput = sample.throughputKbps;

    _firstPosition ??= sample.position;
    if (sample.position > _firstPosition!) _advanced = true;

    final stalled = sample.buffering && sample.playing;
    if (stalled && !_inStall) _stalls.add(sample.at);
    _inStall = stalled;

    if (sample.playing && !sample.buffering) {
      _playingTime += const Duration(seconds: 1);
    }

    final previous = _previousAhead;
    if (previous != null &&
        sample.bufferedAhead < previous &&
        sample.bufferedAhead < thresholds.drainBelow) {
      _drainRun++;
    } else {
      _drainRun = 0;
    }
    _previousAhead = sample.bufferedAhead;

    _recentDrops.add(sample.droppedFrames ?? 0);
    final keep =
        thresholds.dropWindow.inSeconds * thresholds.sustainedDropWindows;
    while (_recentDrops.length > keep) {
      _recentDrops.removeAt(0);
    }
  }

  int _dropLimit() =>
      (thresholds.maxDropsPerSecond * thresholds.dropWindow.inSeconds).round();

  bool _hasCompleteDropWindow() =>
      _recentDrops.length >= thresholds.dropWindow.inSeconds;

  /// Drops in the most recent [AdaptationThresholds.dropWindow].
  int _lastWindowDrops() {
    final size = thresholds.dropWindow.inSeconds;
    final start = _recentDrops.length > size ? _recentDrops.length - size : 0;
    var sum = 0;
    for (var i = start; i < _recentDrops.length; i++) {
      sum += _recentDrops[i];
    }
    return sum;
  }

  /// Whether every one of the last [sustainedDropWindows] windows exceeded
  /// the limit. Needs the full history first.
  bool _sustainedDrops() {
    final size = thresholds.dropWindow.inSeconds;
    final windows = thresholds.sustainedDropWindows;
    if (_recentDrops.length < size * windows) return false;
    for (var w = 0; w < windows; w++) {
      var sum = 0;
      final end = _recentDrops.length - w * size;
      for (var i = end - size; i < end; i++) {
        sum += _recentDrops[i];
      }
      if (sum <= _dropLimit()) return false;
    }
    return true;
  }

  int _stallsWithin(Duration window, Duration now) =>
      _stalls.where((at) => now - at <= window).length;

  AdaptationAction _fallback(FailureReason reason) =>
      FallbackToTranscode(reason: reason, throughputKbps: _lastThroughput);

  AdaptationAction _verify(HealthSample sample) {
    if (sample.fault && !_advanced) {
      return _fallback(FailureReason.decodeFailed);
    }
    if (_hasCompleteDropWindow() && _lastWindowDrops() > _dropLimit()) {
      return _fallback(FailureReason.decodeTooSlow);
    }
    if (_stalls.length >= thresholds.verificationStalls) {
      return _fallback(FailureReason.bandwidth);
    }
    if (_drainRun >= thresholds.drainSamples) {
      return _fallback(FailureReason.bandwidth);
    }
    return const NoAction();
  }

  AdaptationAction _later(HealthSample sample) {
    if (_sustainedDrops()) return _fallback(FailureReason.decodeTooSlow);
    if (_stallsWithin(thresholds.laterStallWindow, sample.at) >=
        thresholds.laterStalls) {
      return _fallback(FailureReason.bandwidth);
    }
    if (_drainRun >= thresholds.drainSamples) {
      return _fallback(FailureReason.bandwidth);
    }
    return const NoAction();
  }
}

/// The OSD line for a fallback.
String fallbackMessage(FailureReason reason) => switch (reason) {
      FailureReason.decodeFailed ||
      FailureReason.decodeTooSlow =>
        'Switched to transcoding: your device dropped frames',
      FailureReason.bandwidth => 'Switched to transcoding for your connection',
    };
