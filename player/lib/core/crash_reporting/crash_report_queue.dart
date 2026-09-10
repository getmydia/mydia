import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// What one POST to `/crashes/report` came to.
enum SendOutcome {
  /// 201. Both relays also answer 201 when their own throttle drops a report.
  sent,

  /// 400. The relay rejected the body, and resending it can never succeed.
  rejected,

  /// 429. Retried after [SendResult.retryAfter] when the relay gave one.
  rateLimited,

  /// Any other status, a network error, or a timeout.
  failed,
}

class SendResult {
  const SendResult(this.outcome, {this.retryAfter});

  factory SendResult.fromStatus(int status, {String? retryAfterHeader}) {
    switch (status) {
      case 201:
        return const SendResult(SendOutcome.sent);
      case 400:
        return const SendResult(SendOutcome.rejected);
      case 429:
        // Whole seconds only; the Elixir relay sends "60". An HTTP date or a
        // non-positive value falls back to the normal backoff.
        final seconds = int.tryParse(retryAfterHeader?.trim() ?? '');
        return SendResult(
          SendOutcome.rateLimited,
          retryAfter: seconds == null || seconds < 1
              ? null
              : Duration(seconds: seconds),
        );
      default:
        return const SendResult(SendOutcome.failed);
    }
  }

  final SendOutcome outcome;
  final Duration? retryAfter;
}

/// Crash reports waiting to be delivered, retried with backoff.
///
/// The numbers are the server's (`Mydia.CrashReporter.Queue`). The queue is
/// never written to disk: Hive or secure storage may be the very thing that
/// just failed, and the server's queue is in memory too. Unsent reports are
/// lost when the app exits.
class CrashReportQueue {
  CrashReportQueue({
    required http.Client client,
    required Uri endpoint,
    DateTime Function()? now,
    this.maxLength = 20,
  })  : _client = client,
        _endpoint = endpoint,
        _now = now ?? DateTime.now;

  static const initialBackoff = Duration(seconds: 60);
  static const maxBackoff = Duration(minutes: 8);
  static const maxAttempts = 10;
  static const maxAge = Duration(hours: 24);
  static const requestTimeout = Duration(seconds: 10);

  final http.Client _client;
  final Uri _endpoint;
  final DateTime Function() _now;

  /// When full, the oldest report is dropped to make room.
  final int maxLength;

  final List<_QueuedReport> _entries = [];
  Timer? _timer;
  bool _draining = false;

  int get length => _entries.length;

  void enqueue(Map<String, Object?> body) {
    if (_entries.length >= maxLength) _entries.removeAt(0);
    final now = _now();
    _entries.add(_QueuedReport(body, queuedAt: now, nextAttemptAt: now));
    unawaited(_drain());
  }

  /// One POST, no retry. Never throws.
  Future<SendResult> sendOnce(Map<String, Object?> body) async {
    try {
      final response = await _client
          .post(
            _endpoint,
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(requestTimeout);
      return SendResult.fromStatus(
        response.statusCode,
        retryAfterHeader: response.headers['retry-after'],
      );
    } catch (e) {
      debugPrint('[CrashReporter] Send failed: $e');
      return const SendResult(SendOutcome.failed);
    }
  }

  /// The wait after [failures] consecutive failures: 60 s, doubling, held at
  /// 8 minutes.
  static Duration backoffAfter(int failures) {
    final seconds = initialBackoff.inSeconds << (failures - 1);
    return seconds >= maxBackoff.inSeconds
        ? maxBackoff
        : Duration(seconds: seconds);
  }

  /// Stops retrying and drops everything queued.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _entries.clear();
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    _timer?.cancel();
    _timer = null;
    try {
      // A copy: enqueue may add, and a full queue may drop, while a send is
      // in flight. Anything added meanwhile is picked up by _scheduleNext.
      for (final entry in List.of(_entries)) {
        if (entry.nextAttemptAt.isAfter(_now())) continue;
        final result = await sendOnce(entry.body);
        switch (result.outcome) {
          case SendOutcome.sent:
          case SendOutcome.rejected:
            _entries.remove(entry);
          case SendOutcome.rateLimited:
          case SendOutcome.failed:
            entry.failures++;
            final expired = entry.failures >= maxAttempts ||
                _now().difference(entry.queuedAt) >= maxAge;
            if (expired) {
              _entries.remove(entry);
            } else {
              entry.nextAttemptAt =
                  _now().add(result.retryAfter ?? backoffAfter(entry.failures));
            }
        }
      }
    } finally {
      _draining = false;
      _scheduleNext();
    }
  }

  void _scheduleNext() {
    if (_entries.isEmpty) return;
    var next = _entries.first.nextAttemptAt;
    for (final entry in _entries) {
      if (entry.nextAttemptAt.isBefore(next)) next = entry.nextAttemptAt;
    }
    final delay = next.difference(_now());
    _timer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(_drain()),
    );
  }
}

class _QueuedReport {
  _QueuedReport(
    this.body, {
    required this.queuedAt,
    required this.nextAttemptAt,
  });

  final Map<String, Object?> body;
  final DateTime queuedAt;
  DateTime nextAttemptAt;
  int failures = 0;
}
