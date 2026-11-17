/// Which video output macOS playback uses.
library;

import 'package:flutter/foundation.dart';

/// [texture] is media_kit's stock `Video` widget. [surface] is the mpv
/// gpu-next platform view that can reach the display's HDR range.
enum VideoOutputPath { texture, surface }

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
  final eligible = platform == TargetPlatform.macOS &&
      !isWeb &&
      !legacyHatch &&
      failedVersion != appVersion;
  return eligible ? VideoOutputPath.surface : VideoOutputPath.texture;
}
