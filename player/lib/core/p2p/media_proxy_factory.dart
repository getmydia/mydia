import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/core/p2p/media_proxy.dart';

import 'media_proxy_stub.dart'
    if (dart.library.js_interop) 'media_proxy_web.dart' as impl;

/// The media proxy for this platform: a loopback HTTP server everywhere a
/// socket can be bound, a Service Worker in the browser.
///
/// Playback call sites read this rather than `localProxyServiceProvider`, so
/// the URL they hand the video pipeline comes from whichever proxy is actually
/// serving. On native the two providers hold the same object.
final mediaProxyProvider =
    Provider<MediaProxy>((ref) => impl.createMediaProxy(ref));
