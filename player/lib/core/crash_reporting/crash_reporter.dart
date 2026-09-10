import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../relay/relay_api_client.dart' show metadataRelayBaseUrl;
import '../settings/settings_service.dart';
import 'crash_app_context.dart';
import 'crash_report.dart';
import 'crash_report_queue.dart';
import 'crash_sanitizer.dart';
import 'startup_report_controller.dart';

/// Sends the player's crashes to the relay's `POST /crashes/report`, the
/// endpoint the mydia server's `Mydia.CrashReporter` already uses.
///
/// Nothing is sent until the user opts in. The parts mirror the server's:
/// [install] stands in for its Tower reporter, `_Throttle` for `Throttle`,
/// `sanitizeReport` for `Sanitizer`, and [CrashReportQueue] for `Queue` and
/// `Sender`.
///
/// Everything after capture runs in the reporter's own guarded zone, so an
/// error raised while reporting is logged and never reported, and no handler
/// installed here can throw.
class CrashReporter {
  CrashReporter({
    required http.Client client,
    required Uri endpoint,
    required Future<bool> Function() loadConsent,
    required Future<void> Function(bool enabled) saveConsent,
    required Future<CrashAppContext> Function() loadAppContext,
    this.isAvailable = true,
    DateTime Function()? now,
    void Function(FlutterErrorDetails details)? presentFlutterError,
    Duration consentTimeout = const Duration(seconds: 2),
  })  : _loadConsent = loadConsent,
        _saveConsent = saveConsent,
        _loadAppContext = loadAppContext,
        _now = now ?? DateTime.now,
        _presentFlutterError = presentFlutterError ??
            ((details) => FlutterError.presentError(details)),
        _consentTimeout = consentTimeout,
        _throttle = _Throttle(now ?? DateTime.now),
        _queue = CrashReportQueue(client: client, endpoint: endpoint, now: now);

  /// The reporter `main()` installs.
  ///
  /// Consent lives in [SettingsService], built on first use so nothing
  /// touches storage before the binding exists. Web builds install the
  /// handlers but send nothing: dart2js traces are minified, and neither
  /// relay answers CORS for `/crashes/report`.
  factory CrashReporter.production() {
    SettingsService? settings;
    SettingsService settingsService() => settings ??= SettingsService();
    return CrashReporter(
      client: http.Client(),
      endpoint: Uri.parse('$metadataRelayBaseUrl/crashes/report'),
      loadConsent: () => settingsService().getCrashReportingEnabled(),
      saveConsent: (enabled) =>
          settingsService().setCrashReportingEnabled(enabled),
      loadAppContext: loadCrashAppContext,
      isAvailable: !kIsWeb,
    );
  }

  /// Sends nothing and stores nothing. What `crashReporterProvider` hands to
  /// code running without `main()`'s override, such as widget tests that
  /// pump the whole app.
  factory CrashReporter.inert() => CrashReporter(
        client: _NoNetworkClient(),
        endpoint: Uri(),
        loadConsent: () async => false,
        saveConsent: (_) async {},
        loadAppContext: () async => const CrashAppContext(
          version: '',
          buildNumber: '',
          platform: '',
          osVersion: '',
          environment: '',
        ),
        isAvailable: false,
      );

  /// False on web and for [CrashReporter.inert]. The handlers still log, but
  /// nothing is sent, [reportStartupFailure] returns null, and the settings
  /// row is hidden.
  final bool isAvailable;

  final Future<bool> Function() _loadConsent;
  final Future<void> Function(bool enabled) _saveConsent;
  final Future<CrashAppContext> Function() _loadAppContext;
  final DateTime Function() _now;
  final void Function(FlutterErrorDetails details) _presentFlutterError;
  final Duration _consentTimeout;
  final _Throttle _throttle;
  final CrashReportQueue _queue;
  final Set<String> _seen = {};
  bool? _consent;
  CrashAppContext? _appContext;

  /// Routes Flutter framework errors, and errors raised outside any zone,
  /// through this reporter.
  void install() {
    FlutterError.onError = handleFlutterError;
    PlatformDispatcher.instance.onError = handlePlatformError;
  }

  /// Presents and logs the error exactly as `main()` always has, then
  /// reports it.
  @visibleForTesting
  void handleFlutterError(FlutterErrorDetails details) {
    _presentFlutterError(details);
    debugPrint('Flutter error: ${details.exception}');
    debugPrint('Stack trace: ${details.stack}');
    // Flutter marks environmental failures, image loads among them, silent.
    if (details.silent) return;
    unawaited(
      report(
        details.exception,
        details.stack,
        capture: CrashCapture.flutterError,
      ),
    );
  }

  @visibleForTesting
  bool handlePlatformError(Object error, StackTrace stack) {
    debugPrint('Platform error: $error');
    debugPrint('Stack trace: $stack');
    unawaited(report(error, stack, capture: CrashCapture.platformDispatcher));
    return true;
  }

  /// Reports an unhandled error, when the user has opted in.
  ///
  /// Consent first, so nothing is built when it is off; then the per-session
  /// dedup, then the throttle, then the queue. Completes once the report is
  /// queued or dropped, not when it is delivered. Never throws.
  Future<void> report(
    Object error,
    StackTrace? stack, {
    required CrashCapture capture,
  }) {
    if (!isAvailable) return Future<void>.value();
    final occurredAt = _now();
    return _guarded<void>(() async {
      if (!await _consentGranted()) return;
      final body = await _body(
        error,
        stack,
        capture: capture,
        occurredAt: occurredAt,
        manual: false,
      );
      if (!_seen.add(crashDedupKey(body))) return;
      if (!_throttle.allow()) return;
      _queue.enqueue(body);
    }, null);
  }

  /// Reports a fatal startup failure through the returned controller: sent at
  /// once when the user has opted in, otherwise held until they tap Send
  /// report. Null when unavailable.
  ///
  /// Never throws. It runs inside `_startApp`, which must reach `runApp` on
  /// every path.
  StartupReportController? reportStartupFailure(
    Object error,
    StackTrace stack,
  ) {
    if (!isAvailable) return null;
    final occurredAt = _now();
    final controller = StartupReportController(
      send: ({required bool manual}) => _guarded(() async {
        final body = await _body(
          error,
          stack,
          capture: CrashCapture.startup,
          occurredAt: occurredAt,
          manual: manual,
        );
        final result = await _queue.sendOnce(body);
        return result.outcome == SendOutcome.sent;
      }, false),
    );
    unawaited(
      _guarded<void>(() async {
        if (await _consentGranted()) await controller.send(manual: false);
      }, null),
    );
    return controller;
  }

  /// Whether the user has opted in. False when consent cannot be read.
  Future<bool> isEnabled() =>
      isAvailable ? _consentGranted() : Future<bool>.value(false);

  /// Stores the user's choice and applies it from the next report on.
  ///
  /// Throws when the choice could not be stored, leaving the previous one in
  /// force.
  Future<void> setEnabled(bool enabled) async {
    await _saveConsent(enabled);
    _consent = enabled;
  }

  Future<bool> _consentGranted() async {
    final cached = _consent;
    if (cached != null) return cached;
    try {
      final granted = await _loadConsent().timeout(_consentTimeout);
      _consent = granted;
      return granted;
    } catch (e) {
      // A locked keyring or a slow read. Off for this report, and read again
      // next time rather than caching a guess.
      debugPrint('[CrashReporter] Could not read consent: $e');
      return false;
    }
  }

  Future<Map<String, Object?>> _body(
    Object error,
    StackTrace? stack, {
    required CrashCapture capture,
    required DateTime occurredAt,
    required bool manual,
  }) async {
    final context = _appContext ??= await _loadAppContext();
    final report = CrashReport.fromError(
      error,
      stack,
      capture: capture,
      context: context,
      occurredAt: occurredAt,
      manual: manual,
    );
    return sanitizeReport(report.toJson());
  }

  // Runs [work] in its own error zone. Whatever it throws, synchronously, from
  // a stray future, or later from a queue retry timer (timers keep the zone
  // they were created in), lands here instead of in FlutterError.onError or
  // main()'s zone, which would report it again. A reentrancy flag would not
  // do: it would also drop an unrelated crash arriving while this report
  // waits on its consent read.
  Future<T> _guarded<T>(Future<T> Function() work, T fallback) {
    final done = Completer<T>();
    runZonedGuarded(
      () async {
        final result = await work();
        if (!done.isCompleted) done.complete(result);
      },
      (error, stack) {
        debugPrint('[CrashReporter] Internal error: $error');
        if (!done.isCompleted) done.complete(fallback);
      },
    );
    return done.future;
  }
}

// Fixed window, the numbers Mydia.CrashReporter.Throttle uses: at most 10
// reports in any 60-second window.
class _Throttle {
  _Throttle(this._now);

  static const _window = Duration(seconds: 60);
  static const _max = 10;

  final DateTime Function() _now;
  DateTime? _windowStart;
  int _count = 0;

  bool allow() {
    final now = _now();
    final start = _windowStart;
    if (start == null || now.difference(start) >= _window) {
      _windowStart = now;
      _count = 0;
    }
    if (_count >= _max) return false;
    _count++;
    return true;
  }
}

class _NoNetworkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw StateError('CrashReporter.inert() never sends');
}
