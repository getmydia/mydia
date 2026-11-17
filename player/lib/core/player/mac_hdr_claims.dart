/// The HDR formats macOS claims, which follow the output path that will
/// render them.
///
/// The server direct-plays an HDR file only to a client sharing a token with
/// it (see `hdr_claims.dart`), so the claim must match what the output can
/// show: the mpv gpu-next surface reaches the display's HDR range and the
/// texture does not.
library;

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
/// Without a [resolvePath] macOS claims the texture's list, which is what it
/// claimed before the surface existed.
Future<List<String>> nativeProfileHdrFormats({
  required bool isMacOS,
  Future<VideoOutputPath> Function()? resolvePath,
}) async {
  if (!isMacOS) return nativeHdrFormats;
  final path = await resolvePath?.call() ?? VideoOutputPath.texture;
  return macHdrFormats(path);
}
