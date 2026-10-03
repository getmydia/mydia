import 'package:flutter/foundation.dart';

/// Tracks download speed using a rolling time window.
///
/// Records byte progress samples per task and computes speed (bytes/sec)
/// and ETA from a 5-second sliding window. Singleton via [instance].
class DownloadSpeedTracker {
  DownloadSpeedTracker._();
  static final instance = DownloadSpeedTracker._();

  static const _windowDuration = Duration(seconds: 5);
  static const _minSampleInterval = Duration(milliseconds: 500);

  /// Samples keyed by task ID: list of (time, cumulativeBytes).
  final Map<String, List<_Sample>> _samples = {};

  /// Record cumulative bytes downloaded for [taskId].
  void recordProgress(String taskId, int cumulativeBytes) {
    final now = DateTime.now();
    final list = _samples.putIfAbsent(taskId, () => []);

    // Skip if too close to last sample
    if (list.isNotEmpty &&
        now.difference(list.last.time) < _minSampleInterval) {
      return;
    }

    list.add(_Sample(now, cumulativeBytes));

    // Prune samples outside the window
    final cutoff = now.subtract(_windowDuration);
    list.removeWhere((s) => s.time.isBefore(cutoff));

    debugPrint(
        '[SpeedTracker] recordProgress($taskId): $cumulativeBytes bytes, ${list.length} samples');
  }

  /// Returns bytes per second for [taskId], or 0 if insufficient data.
  double getSpeedBytesPerSecond(String taskId) {
    final list = _samples[taskId];
    if (list == null || list.length < 2) {
      debugPrint(
          '[SpeedTracker] getSpeed($taskId): insufficient samples (${list?.length ?? 0})');
      return 0;
    }

    final oldest = list.first;
    final newest = list.last;
    final elapsed = newest.time.difference(oldest.time).inMilliseconds;

    if (elapsed < _minSampleInterval.inMilliseconds) {
      debugPrint(
          '[SpeedTracker] getSpeed($taskId): elapsed too short (${elapsed}ms)');
      return 0;
    }

    final bytesDelta = newest.bytes - oldest.bytes;
    if (bytesDelta <= 0) {
      debugPrint(
          '[SpeedTracker] getSpeed($taskId): no byte delta (oldest=${oldest.bytes}, newest=${newest.bytes})');
      return 0;
    }

    final speed = bytesDelta / (elapsed / 1000.0);
    debugPrint(
        '[SpeedTracker] getSpeed($taskId): ${(speed / 1024 / 1024).toStringAsFixed(2)} MB/s');
    return speed;
  }

  /// Returns estimated remaining [Duration] for [taskId], or null.
  Duration? getEta(String taskId, int totalBytes) {
    final speed = getSpeedBytesPerSecond(taskId);
    if (speed <= 0 || totalBytes <= 0) return null;

    final list = _samples[taskId];
    if (list == null || list.isEmpty) return null;

    final remaining = totalBytes - list.last.bytes;
    if (remaining <= 0) return null;

    final seconds = remaining / speed;
    return Duration(seconds: seconds.round());
  }

  /// Remove all samples for [taskId].
  void clearTask(String taskId) {
    _samples.remove(taskId);
  }
}

class _Sample {
  final DateTime time;
  final int bytes;
  const _Sample(this.time, this.bytes);
}
