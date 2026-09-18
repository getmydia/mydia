import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

import '../../../domain/models/available_update.dart';
import '../platform_updater.dart';
import '../update_track.dart';

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
    } on MissingPluginException catch (e) {
      debugPrint('[MacOSUpdater] Sparkle host unavailable: $e');
    }
  }

  /// The track Sparkle is currently allowed to offer, as
  /// [SparkleUpdateBackend]'s default track source.
  ///
  /// The value lives in macOS user defaults, owned by the Swift side, because
  /// Sparkle asks for the allowed channels through a synchronous callback
  /// that cannot wait on Dart.
  static Future<UpdateTrack> currentTrack({
    MethodChannel channel = kSparkleChannel,
  }) async {
    try {
      final name = await channel.invokeMethod<String>('getTrack');
      return UpdateTrack.fromWireName(name) ?? UpdateTrack.stable;
    } on PlatformException catch (e) {
      debugPrint('[MacOSUpdater] Sparkle getTrack failed: $e');
      return UpdateTrack.stable;
    } on MissingPluginException catch (e) {
      debugPrint('[MacOSUpdater] Sparkle host unavailable: $e');
      return UpdateTrack.stable;
    }
  }

  /// Points Sparkle at a track, as [SparkleUpdateBackend]'s default track
  /// sink. Returns true when the host accepted it.
  ///
  /// On anything but stable the host also runs a check immediately, so the
  /// change is visible without waiting for the next scheduled one. That
  /// happens on the Swift side, not here.
  static Future<bool> setTrack(
    UpdateTrack track, {
    MethodChannel channel = kSparkleChannel,
  }) async {
    try {
      await channel.invokeMethod('setTrack', track.wireName);
      return true;
    } on PlatformException catch (e) {
      debugPrint('[MacOSUpdater] Sparkle setTrack failed: $e');
      return false;
    } on MissingPluginException catch (e) {
      debugPrint('[MacOSUpdater] Sparkle host unavailable: $e');
      return false;
    }
  }
}
