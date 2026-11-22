/// Which video output macOS playback uses.
library;

import 'package:flutter/foundation.dart';

/// [texture] is media_kit's stock `Video` widget. [surface] is the mpv
/// gpu-next platform view that can reach the display's HDR range.
enum VideoOutputPath { texture, surface }

/// Which output one playback uses, and whether a failure recorded for this
/// app version is why it is the texture.
typedef MacVideoOutputChoice = ({VideoOutputPath path, bool failedEarlier});

/// Decides the output for one playback.
///
/// The surface is used only on native macOS, with the legacy escape hatch off,
/// and unless the surface failed to start on this very app version. A failure
/// recorded by an older version is ignored, so an update gets one more try.
VideoOutputPath chooseVideoOutputPath({
  required TargetPlatform platform,
  required bool isWeb,
  required bool legacyHatch,
  required String? failedVersion,
  required String appVersion,
}) {
  final eligible =
      platform == TargetPlatform.macOS &&
      !isWeb &&
      !legacyHatch &&
      failedVersion != appVersion;
  return eligible ? VideoOutputPath.surface : VideoOutputPath.texture;
}

/// The running build's version through [read] (`installedVersionReaderProvider`),
/// or empty when it cannot be read.
///
/// Awaited rather than taken from `updateProvider`, whose version stays
/// empty until its own read lands: a playback started before then would
/// skip a failure recorded on this version, and could not record one.
Future<String> readInstalledVersion(Future<String> Function() read) async {
  try {
    return await read();
  } catch (e) {
    debugPrint('[MpvSurface] Could not read the app version: $e');
    return '';
  }
}

/// Reads the hatch and the recorded failure, then decides with
/// [chooseVideoOutputPath]. The one resolution the player screen and the
/// device profile share, so a capability claim and the output that renders
/// it cannot disagree.
///
/// Each read stands alone: one that throws counts as "no hatch" or "no
/// failure", as the screen always treated it, and does not hide the other.
Future<MacVideoOutputChoice> resolveVideoOutputChoice({
  required Future<bool> Function() readLegacyHatch,
  required Future<String?> Function() readFailedVersion,
  required String appVersion,
  TargetPlatform? platform,
  bool? isWeb,
}) async {
  final target = platform ?? defaultTargetPlatform;
  final web = isWeb ?? kIsWeb;
  var legacy = false;
  String? failedVersion;
  try {
    legacy = await readLegacyHatch();
  } catch (e) {
    debugPrint('[MpvSurface] Could not read the legacy output setting: $e');
  }
  try {
    failedVersion = await readFailedVersion();
  } catch (e) {
    debugPrint('[MpvSurface] Could not read the surface failure marker: $e');
  }
  final path = chooseVideoOutputPath(
    platform: target,
    isWeb: web,
    legacyHatch: legacy,
    failedVersion: failedVersion,
    appVersion: appVersion,
  );
  return (
    path: path,
    failedEarlier:
        !legacy && failedVersion != null && failedVersion == appVersion,
  );
}
