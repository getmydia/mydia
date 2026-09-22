/// Sends the local log to the relay's `POST /player-logs`.
///
/// Two modes share one wire format (gzipped NDJSON, a meta line first):
///
/// * Continuous, while the Diagnostics choice shares logs: every [interval],
///   whenever [sizeTrigger] bytes are waiting, and when the app goes to the
///   background. The store's cursor advances only on a 2xx, so an offline
///   stretch loses nothing but what rotation drops.
/// * [sendReport], once, on request: every local record under one code.
///
/// The relay's `MetadataRelay.PlayerLogs.Handler` is the other end.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'log_record.dart';
import 'log_store.dart';

/// What the meta line says about this install.
class LogUploadMeta {
  const LogUploadMeta({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.osVersion,
    required this.appVersion,
    required this.build,
  });

  final String deviceId;
  final String deviceName;
  final String platform;
  final String osVersion;
  final String appVersion;
  final String build;

  Map<String, Object?> toJson({
    required String kind,
    String? report,
    String? note,
  }) =>
      {
        'type': 'meta',
        'kind': kind,
        'device_id': deviceId,
        'device_name': deviceName,
        'platform': platform,
        'os_version': osVersion,
        'app_version': appVersion,
        'build': build,
        'report': report,
        'note': note,
      };
}

class LogUploadException implements Exception {
  const LogUploadException(this.message);

  final String message;

  @override
  String toString() => message;
}

sealed class _Outcome {
  const _Outcome();
}

final class _Sent extends _Outcome {
  const _Sent(this.code);

  final String? code;
}

final class _Rejected extends _Outcome {
  const _Rejected();
}

final class _Wait extends _Outcome {
  const _Wait(this.until);

  final DateTime until;
}

/// The batch was too large for the relay; retry the same cursor with a
/// smaller byte budget.
final class _Shrink extends _Outcome {
  const _Shrink();
}

class LogUploader {
  LogUploader({
    required http.Client client,
    required Uri endpoint,
    required LogStore store,
    required String sessionId,
    required Future<LogUploadMeta> Function() loadMeta,
    required List<int> Function(List<int> bytes) compress,
    DateTime Function()? now,
    this.interval = const Duration(seconds: 60),
    this.maxBatchBytes = 2 * 1024 * 1024,
  })  : _client = client,
        _endpoint = endpoint,
        _store = store,
        _sessionId = sessionId,
        _loadMeta = loadMeta,
        _compress = compress,
        _now = now ?? DateTime.now;

  static const sizeTrigger = 256 * 1024;
  static const minBackoff = Duration(seconds: 30);
  static const maxBackoff = Duration(minutes: 30);
  static const missingEndpointBackoff = Duration(hours: 1);
  static const requestTimeout = Duration(seconds: 30);

  /// Floor for the byte budget a 413 shrinks toward.
  static const _minBatchBytes = 64 * 1024;

  final Duration interval;

  /// Raw text per request, well under the relay's 8 MB decompressed cap.
  final int maxBatchBytes;

  final http.Client _client;
  final Uri _endpoint;
  final LogStore _store;
  final String _sessionId;
  final Future<LogUploadMeta> Function() _loadMeta;
  final List<int> Function(List<int> bytes) _compress;
  final DateTime Function() _now;

  bool _active = false;
  DateTime? _until;
  Timer? _timer;
  int _unsent = 0;
  bool _busy = false;
  DateTime? _notBefore;
  Duration _backoff = Duration.zero;

  bool get isActive => _active;

  @visibleForTesting
  Duration get backoff => _backoff;

  /// Starts continuous upload, sending nothing timestamped after [until].
  ///
  /// [resetCursor] moves the cursor past everything already written, so
  /// nothing captured before the user chose to share is sent.
  Future<void> activate({
    required DateTime? until,
    required bool resetCursor,
  }) async {
    _until = until;
    if (resetCursor) await _store.saveCursor(await _store.endCursor());
    if (_active) return;
    _active = true;
    _unsent = 0;
    _store.onFlushed = _onFlushed;
    _timer = Timer.periodic(interval, (_) => unawaited(tick()));
  }

  /// Stops continuous upload, after one last attempt when [finalAttempt].
  Future<void> deactivate({bool finalAttempt = false}) async {
    if (!_active) return;
    _timer?.cancel();
    _timer = null;
    _store.onFlushed = null;
    try {
      if (finalAttempt) {
        _notBefore = null;
        await tick();
      }
    } finally {
      _active = false;
      _until = null;
    }
  }

  /// Uploads what is waiting now, for the app going to the background.
  Future<void> flushNow() async {
    if (!_active) return;
    await _store.flush();
    await tick();
  }

  /// One continuous-upload pass. Never throws.
  Future<void> tick() async {
    if (!_active || _busy) return;
    final notBefore = _notBefore;
    if (notBefore != null && _now().isBefore(notBefore)) return;
    _busy = true;
    try {
      await _drain();
    } catch (e) {
      _backoff = _backoff == Duration.zero ? minBackoff : _backoff * 2;
      if (_backoff > maxBackoff) _backoff = maxBackoff;
      _notBefore = _now().add(_backoff);
      debugPrint(
          '[LogUploader] Upload failed, retrying in ${_backoff.inSeconds}s: $e');
    } finally {
      _busy = false;
    }
  }

  /// Uploads every local record under one new report code and returns it.
  ///
  /// Works whatever the Diagnostics choice: asking is consent for this one
  /// upload. Records written after the call started are left out, so a busy
  /// log cannot keep it running.
  Future<String> sendReport({String? note}) async {
    try {
      final meta = await _loadMeta();
      final untilMs = _now().millisecondsSinceEpoch;
      String? code;
      LogCursor? from;
      var budget = maxBatchBytes;
      while (true) {
        final batch =
            await _store.read(from: from, maxBytes: budget, untilMs: untilMs);
        if (batch.lines.isEmpty) break;
        final outcome = await _send(
          meta.toJson(
              kind: 'report', report: code, note: code == null ? note : null),
          batch.lines,
        );
        if (outcome is _Shrink) {
          budget = _shrinkBudget(budget);
          continue;
        }
        if (outcome is! _Sent) {
          throw LogUploadException(outcome is _Wait
              ? 'The relay is busy. Try again in a minute.'
              : 'The relay did not accept these logs.');
        }
        budget = maxBatchBytes;
        code ??= outcome.code;
        if (code == null) {
          throw const LogUploadException('The relay did not return a code.');
        }
        from = batch.next;
      }
      if (code == null) {
        throw const LogUploadException('There are no logs on this device yet.');
      }
      return code;
    } on LogUploadException {
      rethrow;
    } catch (_) {
      throw const LogUploadException(
          'Could not reach the relay. Check the connection and try again.');
    }
  }

  void _onFlushed(int bytes) {
    _unsent += bytes;
    if (_unsent >= sizeTrigger) {
      _unsent = 0;
      unawaited(tick());
    }
  }

  Future<void> _drain() async {
    final meta = (await _loadMeta()).toJson(kind: 'stream');
    // Snapshotted once: deactivate() can null out _until while this loop is
    // mid-flight (it runs across several awaited sends), and a later batch
    // must still honor the bound the caller activated with.
    final untilMs = _until?.millisecondsSinceEpoch;
    var cursor = await _store.loadCursor() ?? await _store.endCursor();
    var budget = maxBatchBytes;
    while (true) {
      final batch = await _store.read(
        from: cursor,
        maxBytes: budget,
        untilMs: untilMs,
      );
      if (batch.isEmpty && !batch.gap) {
        if (batch.next != cursor) await _store.saveCursor(batch.next);
        _backoff = Duration.zero;
        _notBefore = null;
        _unsent = 0;
        return;
      }
      final lines = [if (batch.gap) _gapLine(), ...batch.lines];
      switch (await _send(meta, lines)) {
        case _Sent():
          budget = maxBatchBytes;
        case _Rejected():
          debugPrint('[LogUploader] The relay rejected a batch; skipping it');
          budget = maxBatchBytes;
        case _Wait(:final until):
          _notBefore = until;
          return;
        case _Shrink():
          budget = _shrinkBudget(budget);
          continue;
      }
      cursor = batch.next;
      await _store.saveCursor(cursor);
    }
  }

  String _gapLine() => jsonEncode(LogRecord(
        time: _now().toUtc(),
        level: LogLevel.warn,
        tag: 'LogUploader',
        message: 'gap: local logs were rotated away before upload',
        sessionId: _sessionId,
      ).toJson());

  Future<_Outcome> _send(Map<String, Object?> meta, List<String> lines) async {
    final response = await _post(meta, lines);
    final status = response.statusCode;
    if (status >= 200 && status < 300) return _Sent(_codeOf(response));
    // A batch that is still too large after this is a smaller-budget retry
    // from the same cursor, never a split-and-send: the cursor only moves
    // past what one whole request got a full answer for, so a partial
    // success can never be silently resent as a duplicate.
    if (status == 413 && lines.length > 1) return const _Shrink();
    if (status == 400 || status == 413) return const _Rejected();
    if (status == 429) return _Wait(_now().add(_retryAfter(response)));
    if (status == 404) return _Wait(_now().add(missingEndpointBackoff));
    throw LogUploadException('The relay answered HTTP $status');
  }

  static int _shrinkBudget(int budget) {
    final half = budget ~/ 2;
    return half < _minBatchBytes ? _minBatchBytes : half;
  }

  Future<http.Response> _post(Map<String, Object?> meta, List<String> lines) {
    final body = StringBuffer()..writeln(jsonEncode(meta));
    for (final line in lines) {
      body.writeln(line);
    }
    return _client
        .post(
          _endpoint,
          headers: const {
            'content-type': 'application/x-ndjson',
            'content-encoding': 'gzip',
          },
          body: _compress(utf8.encode(body.toString())),
        )
        .timeout(requestTimeout);
  }

  static Duration _retryAfter(http.Response response) {
    final seconds = int.tryParse(response.headers['retry-after'] ?? '');
    return Duration(seconds: seconds == null || seconds < 1 ? 60 : seconds);
  }

  static String? _codeOf(http.Response response) {
    if (response.body.isEmpty) return null;
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map && decoded['code'] is String
          ? decoded['code'] as String
          : null;
    } catch (_) {
      return null;
    }
  }
}
