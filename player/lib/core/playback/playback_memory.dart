/// What this install has learned about playing files from each server.
///
/// Two facts per server: shapes of file that failed to decode here, and a
/// running estimate of throughput to that server. Both are advisory. A
/// missing or unreadable box costs the memory and never the playback.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import 'playback_plan.dart';

const Duration kFailureMemoryTtl = Duration(days: 14);
const double kThroughputAlpha = 0.3;

enum FailureReason { decodeFailed, decodeTooSlow, bandwidth }

/// A file shape that failed to decode on this device.
class FailureKey {
  const FailureKey({required this.videoCodec, required this.heightBucket});

  factory FailureKey.fromShape(FileShape shape) => FailureKey(
        videoCodec: shape.videoCodec,
        heightBucket: shape.heightBucket,
      );

  final String videoCodec;
  final int heightBucket;

  String get storageKey => '$videoCodec|$heightBucket';

  static FailureKey? parse(String raw) {
    final split = raw.lastIndexOf('|');
    if (split <= 0) return null;
    final bucket = int.tryParse(raw.substring(split + 1));
    if (bucket == null) return null;
    return FailureKey(
      videoCodec: raw.substring(0, split),
      heightBucket: bucket,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FailureKey &&
          other.videoCodec == videoCodec &&
          other.heightBucket == heightBucket;

  @override
  int get hashCode => Object.hash(videoCodec, heightBucket);

  @override
  String toString() => 'FailureKey($storageKey)';
}

abstract class PlaybackMemory {
  /// Shapes known to fail against [serverKey], expired entries excluded.
  Set<FailureKey> failuresFor(String serverKey, {required DateTime now});

  Future<void> recordFailure(
    String serverKey,
    FailureKey key,
    FailureReason reason, {
    required DateTime now,
  });

  int? throughputKbps(String serverKey);

  /// Folds one measurement into the estimate: alpha 0.3, seeded by the first.
  Future<void> observeThroughput(String serverKey, int kbps);

  /// Records that throughput is at most [upperKbps]. Never raises the estimate.
  Future<void> boundThroughput(String serverKey, int upperKbps);

  Future<void> clear();
}

/// One server's record, as stored: a map so the Hive box needs no adapter.
class _ServerRecord {
  _ServerRecord({required this.failures, required this.throughputKbps});

  factory _ServerRecord.empty() =>
      _ServerRecord(failures: {}, throughputKbps: null);

  factory _ServerRecord.fromMap(Map raw) {
    final failures = <String, DateTime>{};
    final rawFailures = raw['failures'];
    if (rawFailures is Map) {
      for (final entry in rawFailures.entries) {
        final value = entry.value;
        final at = value is Map ? value['at'] : null;
        final parsed = at is String ? DateTime.tryParse(at) : null;
        final key = entry.key;
        if (key is String && parsed != null) failures[key] = parsed;
      }
    }
    final throughput = raw['throughputKbps'];
    return _ServerRecord(
      failures: failures,
      throughputKbps: throughput is int ? throughput : null,
    );
  }

  /// Storage key to the moment it was recorded.
  final Map<String, DateTime> failures;
  int? throughputKbps;

  Map<String, dynamic> toMap() => {
        'failures': {
          for (final entry in failures.entries)
            entry.key: {'at': entry.value.toUtc().toIso8601String()},
        },
        'throughputKbps': throughputKbps,
      };

  Set<FailureKey> liveFailures(DateTime now) => {
        for (final entry in failures.entries)
          if (now.difference(entry.value) < kFailureMemoryTtl)
            if (FailureKey.parse(entry.key) case final key?) key,
      };

  void observe(int kbps) {
    final current = throughputKbps;
    throughputKbps = current == null
        ? kbps
        : (kThroughputAlpha * kbps + (1 - kThroughputAlpha) * current).round();
  }

  void bound(int upperKbps) {
    final current = throughputKbps;
    throughputKbps =
        current == null || upperKbps < current ? upperKbps : current;
  }
}

class HivePlaybackMemory implements PlaybackMemory {
  static const boxName = 'playback_memory';

  const HivePlaybackMemory(this._box);

  final Box<Map> _box;

  _ServerRecord _read(String serverKey) {
    final raw = _box.get(serverKey);
    if (raw == null) return _ServerRecord.empty();
    try {
      return _ServerRecord.fromMap(raw);
    } catch (e) {
      debugPrint('[PlaybackMemory] Discarding unreadable record: $e');
      unawaited(_box.delete(serverKey));
      return _ServerRecord.empty();
    }
  }

  Future<void> _write(String serverKey, _ServerRecord record) =>
      _box.put(serverKey, record.toMap());

  @override
  Set<FailureKey> failuresFor(String serverKey, {required DateTime now}) =>
      _read(serverKey).liveFailures(now);

  @override
  Future<void> recordFailure(
    String serverKey,
    FailureKey key,
    FailureReason reason, {
    required DateTime now,
  }) async {
    final record = _read(serverKey);
    record.failures[key.storageKey] = now;
    debugPrint('[PlaybackMemory] $serverKey: $key failed (${reason.name})');
    await _write(serverKey, record);
  }

  @override
  int? throughputKbps(String serverKey) => _read(serverKey).throughputKbps;

  @override
  Future<void> observeThroughput(String serverKey, int kbps) async {
    final record = _read(serverKey)..observe(kbps);
    await _write(serverKey, record);
  }

  @override
  Future<void> boundThroughput(String serverKey, int upperKbps) async {
    final record = _read(serverKey)..bound(upperKbps);
    await _write(serverKey, record);
  }

  @override
  Future<void> clear() => _box.clear();
}

class InMemoryPlaybackMemory implements PlaybackMemory {
  final _records = <String, _ServerRecord>{};

  _ServerRecord _record(String serverKey) =>
      _records.putIfAbsent(serverKey, _ServerRecord.empty);

  @override
  Set<FailureKey> failuresFor(String serverKey, {required DateTime now}) =>
      _record(serverKey).liveFailures(now);

  @override
  Future<void> recordFailure(
    String serverKey,
    FailureKey key,
    FailureReason reason, {
    required DateTime now,
  }) async {
    _record(serverKey).failures[key.storageKey] = now;
  }

  @override
  int? throughputKbps(String serverKey) => _record(serverKey).throughputKbps;

  @override
  Future<void> observeThroughput(String serverKey, int kbps) async =>
      _record(serverKey).observe(kbps);

  @override
  Future<void> boundThroughput(String serverKey, int upperKbps) async =>
      _record(serverKey).bound(upperKbps);

  @override
  Future<void> clear() async => _records.clear();
}
