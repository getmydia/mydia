/// The Diagnostics switches, applied.
///
/// [DiagnosticsController] is the only writer of [DiagnosticsSettings].
/// Applying a state tells the crash reporter whether to send
/// (`CrashReporter.applyConsent`) and starts or stops continuous log upload.
/// `MyApp` listens to [diagnosticsProvider] for the app's lifetime, so this
/// runs without the Diagnostics screen being open.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crash_reporting/crash_reporter_provider.dart';
import '../logging/log_uploader.dart';
import 'diagnostics_settings.dart';

final Provider<DiagnosticsSettings> diagnosticsSettingsProvider =
    Provider<DiagnosticsSettings>((ref) => DiagnosticsSettings());

/// Null where there is no on-disk log: web, tests that pump the whole app,
/// or a store that failed to open. `main()` overrides it.
final Provider<LogUploader?> logUploaderProvider =
    Provider<LogUploader?>((ref) => null);

final AsyncNotifierProvider<DiagnosticsController, DiagnosticsState>
    diagnosticsProvider =
    AsyncNotifierProvider<DiagnosticsController, DiagnosticsState>(
        DiagnosticsController.new);

class DiagnosticsController extends AsyncNotifier<DiagnosticsState> {
  // Serializes setCrashes() and setLogs(), so their storage writes,
  // crash-reporter consent and uploader state can never interleave. Each
  // call chains onto this future and replaces it with one that resolves once
  // that call is done, success or failure, so a failed call never wedges the
  // queue behind it, while _enqueue still hands the caller the original
  // error.
  Future<void> _pending = Future<void>.value();

  Future<T> _enqueue<T>(Future<T> Function() work) {
    final result = _pending.then((_) => work());
    _pending = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<DiagnosticsState> build() async {
    // The inert reporter whole-app tests run with, and web: nothing is ever
    // sent, so there is nothing to read or apply.
    if (!ref.read(crashReporterProvider).isAvailable) {
      return DiagnosticsState.off;
    }
    final loaded = await ref.read(diagnosticsSettingsProvider).load();
    await _apply(loaded, resetCursor: false);
    return loaded;
  }

  /// Turns crash reports on or off. Throws when it could not be stored,
  /// leaving the previous state in force.
  Future<void> setCrashes(bool on) =>
      _enqueue(() => _update((s) => s.copyWith(crashes: on)));

  /// Turns continuous log upload on or off. Throws when it could not be
  /// stored, leaving the previous state in force.
  Future<void> setLogs(bool on) =>
      _enqueue(() => _update((s) => s.copyWith(logs: on)));

  Future<void> _update(
      DiagnosticsState Function(DiagnosticsState current) change) async {
    // build() may still be awaiting its own load() when this call was made.
    // Waiting for it here, rather than reading `state` immediately, means
    // this change is layered on top of the state build() loaded instead of
    // being silently clobbered when build() later completes and Riverpod
    // assigns its return value to state.
    await future;
    final current = state.value ?? DiagnosticsState.off;
    final next = change(current);
    await ref.read(diagnosticsSettingsProvider).save(next);
    state = AsyncData(next);
    await _apply(next, resetCursor: !current.logs);
  }

  /// Uploads this device's logs once and returns the report code.
  Future<String> sendReport({String? note}) {
    final uploader = ref.read(logUploaderProvider);
    if (uploader == null) {
      throw const LogUploadException('Logs are not available on this device.');
    }
    return uploader.sendReport(note: note);
  }

  Future<void> _apply(DiagnosticsState next,
      {required bool resetCursor}) async {
    ref.read(crashReporterProvider).applyConsent(next.crashes);
    final uploader = ref.read(logUploaderProvider);
    if (uploader == null) return;
    if (next.logs) {
      await uploader.activate(resetCursor: resetCursor);
    } else {
      await uploader.deactivate();
    }
  }
}
