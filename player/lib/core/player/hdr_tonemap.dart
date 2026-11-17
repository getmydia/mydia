/// Applies [sdrTonemapMpvOptions] to a player's mpv. See `video_output_config.dart`.
library;

import 'package:media_kit/media_kit.dart';

import 'hdr_tonemap_stub.dart' if (dart.library.io) 'hdr_tonemap_native.dart'
    as platform;
import 'mac_video_output.dart';

/// Sets the tonemap properties on [player]. Call once per `Player`, before
/// `open`. A no-op on web, where the browser tonemaps, and on the macOS
/// surface, where libplacebo does (see `sdrTonemapMpvOptionsFor`).
Future<void> applySdrTonemap(Player player, {required VideoOutputPath path}) =>
    platform.applySdrTonemap(player, path: path);
