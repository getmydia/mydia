import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

import '../../../domain/models/app_update.dart';
import '../platform_updater.dart';

/// Method channel to the Sparkle host in AppDelegate.swift.
///
/// Exposed rather than private so tests can mock it, and so every entry point
/// below can take it as an injectable default.
const MethodChannel kSparkleChannel = MethodChannel('dev.mydia.player/sparkle');

/// macOS updater: delegates to Sparkle 2 via a method channel.
///
/// Sparkle handles the entire update lifecycle natively: checking for updates,
/// showing UI, downloading, verifying EdDSA signatures, replacing the app
/// bundle, and relaunching.
class MacOSUpdater extends PlatformUpdater {
  @override
  bool get canUpdateInPlace => true;

  @override
  Future<void> applyUpdate(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    await checkForUpdates();
  }

  /// Triggers Sparkle's "Check for Updates" flow, which shows its own native
  /// macOS UI for download progress, release notes, and restart prompt.
  static Future<void> checkForUpdates({
    MethodChannel channel = kSparkleChannel,
  }) async {
    try {
      await channel.invokeMethod('checkForUpdates');
    } on PlatformException catch (e) {
      debugPrint('[MacOSUpdater] Sparkle checkForUpdates failed: $e');
    }
  }

  /// Whether the user has opted into prerelease builds.
  ///
  /// The value lives in macOS user defaults, owned by the Swift side, because
  /// Sparkle asks for the allowed channels through a synchronous callback that
  /// cannot wait on Dart.
  static Future<bool> betaChannelEnabled({
    MethodChannel channel = kSparkleChannel,
  }) async {
    try {
      return await channel.invokeMethod<bool>('getBetaChannel') ?? false;
    } on PlatformException catch (e) {
      debugPrint('[MacOSUpdater] Sparkle getBetaChannel failed: $e');
      return false;
    }
  }

  /// Opts into or out of prerelease builds. Opting in also runs a check
  /// immediately, so the change is visible without waiting for the schedule.
  static Future<void> setBetaChannel(
    bool enabled, {
    MethodChannel channel = kSparkleChannel,
  }) async {
    try {
      await channel.invokeMethod('setBetaChannel', enabled);
    } on PlatformException catch (e) {
      debugPrint('[MacOSUpdater] Sparkle setBetaChannel failed: $e');
    }
  }
}
