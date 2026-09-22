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

  /// Bumped on [deactivate] and whenever the cursor is reset. [_drain]
  /// snapshots this at entry and rechecks it before every send and cursor
  /// save, so a drain already mid-flight when one of those happens notices
  /// on its next check and stops immediately, rather than continuing to
  /// upload after the user turned sharing off or persisting a stale cursor
  /// over one [activate] just reset. `_busy` alone cannot catch this: it
  /// only stops a *new* drain from starting while one is running, it does
  /// nothing for a drain already in progress when [deactivate] runs.
  int _generation = 0;

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
    if (resetCursor) {
      // Bump before the await below, not after: it closes the window where
      // a drain already in flight (started before this call, from an
      // earlier `activate` that never deactivated first) could still save
      // its own, now-stale cursor after the fresh one lands.
      _generation++;
      await _store.saveCursor(await _store.endCursor());
    }
    if (_active) return;
    _active = true;
    _unsent = 0;
    _store.onFlushed = _onFlushed;
    _timer = Timer.periodic(interval, (_) => unawaited(tick()));
  }

  /// Stops continuous upload, after one last attempt when [finalAttempt].
  Future<void> deactivate({bool finalAttempt = false}) async {
    if (!_active) return;
    // Bumped first, before the optional final tick: a drain already mid-
    // flight from an earlier timer tick snapshotted the previous
    // generation, so this immediately marks it stale. The final-attempt
    // drain started below reads the generation fresh when it begins, so
    // this bump does not cancel the very drain it is about to ask for.
    _generation++;
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
          budget: budget,
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
    // Snapshotted once: a later `deactivate` or cursor-resetting `activate`
    // bumps `_generation` while this loop is mid-flight (it runs across
    // several awaited sends), and `_stale` below compares against that
    // snapshot, not the live value, so this drain notices the change
    // instead of racing it.
    final generation = _generation;
    bool stale() => generation != _generation || !_active;

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
        // Stale here too: `stale()` becoming true while this read was in
        // flight must stop the cursor from being pushed to `batch.next`.
        if (stale()) return;
        if (batch.next != cursor) await _store.saveCursor(batch.next);
        _backoff = Duration.zero;
        _notBefore = null;
        _unsent = 0;
        return;
      }
      // Checked right before the network call: once sharing is off (or the
      // cursor was reset), nothing already-read may go out, even if it was
      // read before the user's choice changed.
      if (stale()) return;
      final lines = [if (batch.gap) _gapLine(), ...batch.lines];
      switch (await _send(meta, lines, budget: budget)) {
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
      // Checked before the save too: a batch that was already sent (and
      // possibly already accepted) while this drain went stale still must
      // not overwrite a cursor an `activate(resetCursor: true)` in the
      // meantime moved on to skip everything, including what this batch
      // just delivered.
      if (stale()) return;
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

  Future<_Outcome> _send(
    Map<String, Object?> meta,
    List<String> lines, {
    required int budget,
  }) async {
    final response = await _post(meta, lines);
    final status = response.statusCode;
    if (status >= 200 && status < 300) return _Sent(_codeOf(response));
    // A batch that is still too large after this is a smaller-budget retry
    // from the same cursor, never a split-and-send: the cursor only moves
    // past what one whole request got a full answer for, so a partial
    // success can never be silently resent as a duplicate.
    //
    // Only shrink while there is room to shrink. A 413 at the smallest
    // batch we are willing to build means the batch itself is unsendable,
    // not that trying smaller would help: _shrinkBudget clamps to the same
    // floor forever, so without this check a relay that keeps answering
    // 413 would keep _drain/sendReport returning _Shrink and their
    // `while (true)` would neither send nor advance the cursor, spinning
    // forever inside a timer callback on the user's device. Reject it
    // instead, the same as an already-single-line batch.
    if (status == 413 && lines.length > 1 && budget > _minBatchBytes) {
      return const _Shrink();
    }
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
