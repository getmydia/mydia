/// Native implementation: there is no browser engine to steer.
///
/// mpv plays HLS itself on every native platform, retrying a `503` the way the
/// server expects, so nothing here needs preparing or releasing. See
/// `hls_engine.dart`.
library;

import 'package:media_kit/media_kit.dart' show Player;

Future<void> prepareHlsEngine() async {}

void releaseHlsEngine(Player player) {}
