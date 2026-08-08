import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/core/p2p/media_proxy.dart';

/// Everywhere but the browser, the media proxy is the loopback HTTP server.
///
/// This returns the instance `localProxyServiceProvider` already holds instead
/// of building a second one. Casting and downloads still reach for that
/// provider directly for the LAN-exposure and port APIs that only exist on
/// native, and two LocalProxyService objects would mean the proxy playback
/// started was not the proxy those call sites were looking at.
MediaProxy createMediaProxy(Ref ref) => ref.watch(localProxyServiceProvider);
