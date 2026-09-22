/// The Diagnostics choice, applied.
///
/// [DiagnosticsController] is the only writer of [DiagnosticsSettings].
/// Applying a choice tells the crash reporter whether to send
/// (`CrashReporter.applyConsent`), starts or stops continuous log upload, and
/// arms a timer for a timed choice's end. `MyApp` listens to
/// [diagnosticsProvider] for the app's lifetime, so this runs without the
/// Diagnostics screen being open.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
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

/// The clock the controller reads. Overridden in tests.
final Provider<DateTime Function()> diagnosticsClockProvider =
    Provider<DateTime Function()>((ref) => DateTime.now);

final AsyncNotifierProvider<DiagnosticsController, DiagnosticsState>
    diagnosticsProvider =
    AsyncNotifierProvider<DiagnosticsController, DiagnosticsState>(
        DiagnosticsController.new);

class DiagnosticsController extends AsyncNotifier<DiagnosticsState> {
  Timer? _expiry;

  DateTime _now() => ref.read(diagnosticsClockProvider)().toUtc();

  @override
  Future<DiagnosticsState> build() async {
    ref.onDispose(() => _expiry?.cancel());
    // The inert reporter whole-app tests run with, and web: nothing is ever
    // sent, so there is nothing to read or apply.
    if (!ref.read(crashReporterProvider).isAvailable) {
      return DiagnosticsState.off;
    }
    final loaded = await ref.read(diagnosticsSettingsProvider).load();
    await _apply(loaded, resetCursor: false);
    return loaded;
  }

  /// Stores [choice] and applies it. Throws when it could not be stored,
  /// leaving the previous choice in force.
  Future<void> select(DiagnosticsChoice choice) async {
    final now = _now();
    final wasSharing = state.value?.logsActiveAt(now) ?? false;
    final next = DiagnosticsState.chosen(choice, now);
    await ref.read(diagnosticsSettingsProvider).save(next);
    state = AsyncData(next);
    await _apply(next, resetCursor: !wasSharing);
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
    ref.read(crashReporterProvider).applyConsent(next.crashesEnabled);
    _expiry?.cancel();
    _expiry = null;

    final now = _now();
    final sharing = next.logsActiveAt(now);
    final uploader = ref.read(logUploaderProvider);
    if (uploader != null) {
      if (sharing) {
        await uploader.activate(
            until: next.logsUntil, resetCursor: resetCursor);
      } else {
        await uploader.deactivate();
      }
    }

    final until = next.logsUntil;
    if (sharing && until != null) {
      _expiry = Timer(until.difference(now), () => unawaited(_expire()));
    }
  }

  Future<void> _expire() async {
    await ref.read(logUploaderProvider)?.deactivate(finalAttempt: true);
    try {
      await select(DiagnosticsChoice.crashes);
    } catch (e) {
      debugPrint('[Diagnostics] Could not store the end of log sharing: $e');
    }
  }
}
