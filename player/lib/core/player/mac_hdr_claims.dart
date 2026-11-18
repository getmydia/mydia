/// The HDR formats macOS claims, from the output path resolved when the
/// device profile is detected.
///
/// The server direct-plays an HDR file only to a client sharing a token with
/// it (see `hdr_claims.dart`), so the claim must match what the output can
/// show: the mpv gpu-next surface reaches the display's HDR range and the
/// texture does not.
///
/// The profile resolves the path once and keeps that claim. A playback can
/// still end up on the texture afterwards (the viewer turns the legacy
/// output on, or the surface fails to start), and the cached claim does not
/// follow it. That is harmless while both paths claim the same tokens, as
/// they do with [macDolbyVisionVerified] false. Before that flag turns true,
/// the claim must be made to follow the output each playback actually uses,
/// or a texture playback would be sent Dolby Vision it cannot show.
library;

import 'package:flutter/foundation.dart' show debugPrint;

import 'hdr_claims.dart';
import 'mac_video_output.dart';

/// Whether Dolby Vision has been checked on real hardware through the
/// surface. Ships false: flip it only after that check, never on reasoning.
const bool macDolbyVisionVerified = false;

/// The `hdrFormats` macOS sends for [path].
///
/// The texture claims what it always has ([nativeHdrFormats]). The surface
/// adds `dolby_vision`, first, only when [dolbyVisionVerified].
List<String> macHdrFormats(
  VideoOutputPath path, {
  bool dolbyVisionVerified = macDolbyVisionVerified,
}) {
  return switch (path) {
    VideoOutputPath.texture => nativeHdrFormats,
    VideoOutputPath.surface => [
        if (dolbyVisionVerified) 'dolby_vision',
        ...nativeHdrFormats,
      ],
  };
}

/// The HDR claim for a native profile: [macHdrFormats] on macOS, resolving
/// the path with [resolvePath], and [nativeHdrFormats] anywhere else.
///
/// A resolver that throws falls back to [nativeHdrFormats]. Without a
/// [resolvePath] macOS claims the texture's list, which is what it claimed
/// before the surface existed.
Future<List<String>> nativeProfileHdrFormats({
  required bool isMacOS,
  Future<VideoOutputPath> Function()? resolvePath,
}) async {
  if (!isMacOS) return nativeHdrFormats;
  // Never throws: profile detection is fire-and-forget, and a throw here
  // would leave macOS with no profile at all.
  try {
    final path = await resolvePath?.call() ?? VideoOutputPath.texture;
    return macHdrFormats(path);
  } catch (e) {
    debugPrint('[DeviceProfile] Could not resolve the macOS output path: $e');
    return nativeHdrFormats;
  }
}
