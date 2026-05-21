import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../domain/models/app_update.dart';
import 'platform_updater.dart';
import 'update_service.dart';
import 'updaters/macos_updater.dart';

/// State for the update system.
class UpdateState {
  /// Available update, if any.
  final AppUpdate? availableUpdate;

  /// Current app version string.
  final String currentVersion;

  /// Whether a check is in progress.
  final bool isChecking;

  /// Whether an update is being downloaded/applied.
  final bool isApplying;

  /// Download progress (0.0 - 1.0) during apply.
  final double downloadProgress;

  /// Error message from the last check or apply attempt.
  final String? error;

  const UpdateState({
    this.availableUpdate,
    this.currentVersion = '',
    this.isChecking = false,
    this.isApplying = false,
    this.downloadProgress = 0.0,
    this.error,
  });

  UpdateState copyWith({
    AppUpdate? availableUpdate,
    String? currentVersion,
    bool? isChecking,
    bool? isApplying,
    double? downloadProgress,
    String? error,
    bool clearUpdate = false,
    bool clearError = false,
  }) {
    return UpdateState(
      availableUpdate:
          clearUpdate ? null : (availableUpdate ?? this.availableUpdate),
      currentVersion: currentVersion ?? this.currentVersion,
      isChecking: isChecking ?? this.isChecking,
      isApplying: isApplying ?? this.isApplying,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Notifier managing update checking and application.
class UpdateNotifier extends Notifier<UpdateState> {
  late final UpdateService _updateService;
  late final PlatformUpdater? _platformUpdater;

  @override
  UpdateState build() {
    _updateService = UpdateService();
    _platformUpdater = PlatformUpdater.forCurrentPlatform();

    // Kick off initial version load + background check
    Future.microtask(_initAndCheck);

    return const UpdateState();
  }

  Future<void> _initAndCheck() async {
    try {
      final info = await PackageInfo.fromPlatform();
      state = state.copyWith(currentVersion: info.version);

      // Skip auto-check on web
      if (kIsWeb) return;

      // On macOS, Sparkle handles auto-checking natively on launch
      if (!kIsWeb && Platform.isMacOS) return;

      await _performCheck(force: false);
    } catch (e) {
      debugPrint('[UpdateNotifier] Init error: $e');
    }
  }

  /// Manually trigger an update check (bypasses rate limit).
  /// On macOS, delegates to Sparkle which shows its own native UI.
  Future<void> checkForUpdate() async {
    if (!kIsWeb && Platform.isMacOS) {
      await MacOSUpdater.checkForUpdates();
      return;
    }
    await _performCheck(force: true);
  }

  Future<void> _performCheck({required bool force}) async {
    if (state.isChecking) return;

    state = state.copyWith(isChecking: true, clearError: true);

    try {
      final update = await _updateService.checkForUpdate(
        currentVersion: state.currentVersion,
        force: force,
      );

      state = state.copyWith(
        availableUpdate: update,
        isChecking: false,
        clearUpdate: update == null,
      );
    } catch (e) {
      state = state.copyWith(
        isChecking: false,
        error: 'Failed to check for updates: $e',
      );
    }
  }

  /// Download and apply the available update.
  Future<void> applyUpdate() async {
    final update = state.availableUpdate;
    if (update == null || _platformUpdater == null || state.isApplying) return;

    state = state.copyWith(
        isApplying: true, downloadProgress: 0.0, clearError: true);

    try {
      await _platformUpdater.applyUpdate(
        update,
        onProgress: (progress) {
          state = state.copyWith(downloadProgress: progress);
        },
      );

      // If we get here, the updater didn't exit the process (e.g. macOS).
      state = state.copyWith(isApplying: false);
    } catch (e) {
      state = state.copyWith(
        isApplying: false,
        error: 'Update failed: $e',
      );
    }
  }

  /// Whether the current platform supports in-place updates.
  bool get canUpdateInPlace => _platformUpdater?.canUpdateInPlace ?? false;
}

/// Global provider for the update system.
final updateProvider = NotifierProvider<UpdateNotifier, UpdateState>(
  UpdateNotifier.new,
);
