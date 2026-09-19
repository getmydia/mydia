/// Native implementation: there is no browser engine to steer.
///
/// mpv plays HLS itself on every native platform, retrying a `503` the way the
/// server expects, so nothing here needs preparing. See `hls_engine.dart`.
library;

Future<void> prepareHlsEngine() async {}
