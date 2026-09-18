/// Stub `track-list` reads for web.
///
/// media_kit's web backend drives an `HTMLVideoElement`; there is no mpv
/// process and no `track-list` to read. Web never lists an mpv-native
/// subtitle track, so an empty answer loses nothing.
library;

import 'package:media_kit/media_kit.dart';

Future<Map<String, int>> subtitleStreamIndices(Player player) async => const {};
