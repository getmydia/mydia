import 'dart:async';
import 'dart:io' show exit;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../domain/models/available_update.dart';
import 'backends/flatpak_update_backend.dart';
import 'update_backend.dart';
import 'update_host.dart';

/// Terminates the process, mirroring Flutter's own `debugPrint`: a mutable
/// top-level seam rather than a direct `exit()` call, so a test can prove
/// [UpdateNotifier.restart] reaches it without ending the test runner.
@visibleForTesting
void Function(int code) debugExitProcess = exit;

/// Builds the backend for this installation. Overridden in tests.
typedef UpdateBackendFactory = UpdateBackend? Function({
  required String currentVersion,
});

final updateBackendFactoryProvider = Provider<UpdateBackendFactory>(
  (ref) => ({required String currentVersion}) => createUpdateBackend(
        UpdateHost.current(),
        currentVersion: currentVersion,
      ),
);

/// State for the update system.
class UpdateState {
  /// Available update, if any. Null on platforms that update elsewhere.
  final AvailableUpdate? availableUpdate;

  /// Current app version string.
  final String currentVersion;

  /// What the settings row should say and do.
  final ManualCheckBehaviour manualCheck;

  /// Whether a check is in progress.
  final bool isChecking;

  /// Whether an update is being downloaded or applied.
  final bool isApplying;

  /// Download progress (0.0 to 1.0) during apply.
  final double downloadProgress;

  /// An update is installed and this process is still on the old build.
  final bool restartRequired;

  /// A neutral message, such as confirming there was nothing to install.
  final String? notice;

  /// Error message from the last check or apply attempt.
  final String? error;

  const UpdateState({
    this.availableUpdate,
    this.currentVersion = '',
    this.manualCheck = ManualCheckBehaviour.unavailable,
    this.isChecking = false,
    this.isApplying = false,
    this.downloadProgress = 0.0,
    this.restartRequired = false,
    this.notice,
    this.error,
  });

  UpdateState copyWith({
    AvailableUpdate? availableUpdate,
    String? currentVersion,
    ManualCheckBehaviour? manualCheck,
    bool? isChecking,
    bool? isApplying,
    double? downloadProgress,
    bool? restartRequired,
    String? notice,
    String? error,
    bool clearUpdate = false,
    bool clearNotice = false,
    bool clearError = false,
  }) {
    return UpdateState(
      availableUpdate:
          clearUpdate ? null : (availableUpdate ?? this.availableUpdate),
      currentVersion: currentVersion ?? this.currentVersion,
      manualCheck: manualCheck ?? this.manualCheck,
      isChecking: isChecking ?? this.isChecking,
      isApplying: isApplying ?? this.isApplying,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      restartRequired: restartRequired ?? this.restartRequired,
      notice: clearNotice ? null : (notice ?? this.notice),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Notifier managing update checking and application.
class UpdateNotifier extends Notifier<UpdateState> {
  UpdateBackend? _backend;
  StreamSubscription<AvailableUpdate?>? _sub;

  @override
  UpdateState build() {
    ref.onDispose(() {
      _sub?.cancel();
      _backend?.dispose();
    });

    Future.microtask(_init);
    return const UpdateState();
  }

  Future<void> _init() async {
    try {
      final info = await PackageInfo.fromPlatform();

      // The container can be disposed while that read is in flight, since
      // build fires this off with an unawaited Future.microtask and nothing
      // holds the provider open for it. Same guard, same reason, as
      // connection_provider.dart and compatibility_provider.dart.
      if (!ref.mounted) return;

      state = state.copyWith(currentVersion: info.version);

      final backend = ref.read(updateBackendFactoryProvider)(
        currentVersion: info.version,
      );
      if (backend == null) return;
      if (!ref.mounted) {
        await backend.dispose();
        return;
      }

      _backend = backend;
      await backend.start();
      if (!ref.mounted) return;

      state = state.copyWith(manualCheck: backend.manualCheck);

      _sub = backend.availability.listen((update) {
        if (!ref.mounted) return;
        state = state.copyWith(
          availableUpdate: update,
          clearUpdate: update == null,
        );
      });

      // A startup refresh is only meaningful for a backend that has to be
      // told to check (checksOnly / unavailable). Flatpak owns its own 30
      // minute timer and Sparkle checks on launch by itself, so calling
      // refresh() on either would just invoke a documented no-op; skipped
      // here rather than relied upon, so a fake backend under test cannot
      // report a spurious refresh from a case that should never reach one.
      // Mirrors the switch in checkForUpdate below.
      switch (backend.manualCheck) {
        case ManualCheckBehaviour.checksOnly:
        case ManualCheckBehaviour.unavailable:
          await backend.refresh();
        case ManualCheckBehaviour.checksAndInstalls:
        case ManualCheckBehaviour.delegatesToSparkle:
          break;
      }
    } catch (e) {
      debugPrint('[UpdateNotifier] Init error: $e');
    }
  }

  /// The settings row was pressed.
  Future<void> checkForUpdate() async {
    final backend = _backend;
    if (backend == null) return;

    switch (backend.manualCheck) {
      case ManualCheckBehaviour.checksAndInstalls:
        await requestUpdate();
      case ManualCheckBehaviour.delegatesToSparkle:
        await backend.requestUpdate();
      case ManualCheckBehaviour.checksOnly:
      case ManualCheckBehaviour.unavailable:
        await _refresh();
    }
  }

  Future<void> _refresh() async {
    // Before the `try`, so the guards inside it do not cover this read and
    // write. Reached unawaited from `checkForUpdate`, which can resume
    // after disposal.
    final backend = _backend;
    if (backend == null || !ref.mounted || state.isChecking) return;

    state =
        state.copyWith(isChecking: true, clearError: true, clearNotice: true);
    try {
      await backend.refresh(force: true);
      if (!ref.mounted) return;
      state = state.copyWith(isChecking: false);
    } catch (e) {
      // Guarded because a disposal that threw out of the try lands here and
      // throws again from the handler, turning a caught error into an
      // unhandled async one.
      if (!ref.mounted) return;
      state = state.copyWith(
        isChecking: false,
        error: 'Failed to check for updates: $e',
      );
    }
  }

  /// The update affordance was pressed.
  Future<void> requestUpdate() async {
    // Reached unawaited from checkForUpdate's switch and directly from the
    // UI, either of which can resume after disposal. Unlike _refresh, there
    // is no try/catch here to lean on: backend.requestUpdate() is contracted
    // not to throw, so this one guard has to cover every state write below
    // rather than just the one before a try block.
    final backend = _backend;
    if (backend == null || !ref.mounted || state.isApplying) return;

    state = state.copyWith(
      isApplying: true,
      downloadProgress: 0.0,
      clearError: true,
      clearNotice: true,
    );

    final outcome = await backend.requestUpdate(
      onProgress: (progress) {
        if (!ref.mounted) return;
        state = state.copyWith(downloadProgress: progress);
      },
    );

    if (!ref.mounted) return;

    state = switch (outcome) {
      UpdateInstalled(:final restartRequired) => state.copyWith(
          isApplying: false,
          restartRequired: restartRequired,
          clearUpdate: true,
        ),
      AlreadyUpToDate() => state.copyWith(
          isApplying: false,
          notice: "You're up to date",
          clearUpdate: true,
        ),
      UpdateUnsupported(:final reason) =>
        state.copyWith(isApplying: false, error: reason),
      UpdateFailed(:final message) =>
        state.copyWith(isApplying: false, error: message),
      UpdateDeferred() => state.copyWith(isApplying: false),
    };
  }

  /// Restart into the newly installed build. Flatpak only; every other
  /// backend replaces the running process itself.
  ///
  /// A failure here is not an update failure. The new build is installed
  /// either way, so the user is told to reopen the app rather than being told
  /// the update did not work.
  Future<void> restart() async {
    final backend = _backend;
    if (backend is! FlatpakUpdateBackend) return;

    try {
      await backend.restart();
    } catch (e) {
      debugPrint('[UpdateNotifier] Restart failed: $e');
      if (!ref.mounted) return;
      state = state.copyWith(
        notice: 'Update installed. Reopen Mydia to finish.',
        restartRequired: false,
      );
      return;
    }

    // backend.restart() issues the portal's Spawn, which STARTS a new
    // process rather than replacing this one: Flatpak's Spawn has no
    // exec-style "replace the caller" semantics. Without exiting here, the
    // freshly spawned process and this one both keep running, both loading
    // the same on-disk p2p Ed25519 identity. Only reached once backend.
    // restart() has actually succeeded; the catch above already returned for
    // a failed one, so its "reopen" notice still gets seen instead of the
    // process disappearing out from under it.
    debugExitProcess(0);
  }

  /// Whether the current platform supports in-place updates.
  bool get canUpdateInPlace => _backend?.canUpdateInPlace ?? false;
}

/// Global provider for the update system.
final updateProvider = NotifierProvider<UpdateNotifier, UpdateState>(
  UpdateNotifier.new,
);
