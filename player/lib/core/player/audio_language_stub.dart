/// Stub audio-language selection for web.
///
/// media_kit's web backend drives an `HTMLVideoElement`, whose `audioTracks`
/// is unimplemented in Chrome and Firefox. There is no property to set and no
/// track list to choose from, so the browser's own selection stands. The
/// server-side `-map` still applies on the HLS and remux paths, which is
/// where web playback gets its audio anyway.
library;

import 'package:media_kit/media_kit.dart';

Future<void> setAudioLanguage(Player player, List<String> languages) async {}
