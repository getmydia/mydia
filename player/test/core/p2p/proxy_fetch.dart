import 'dart:typed_data';

import 'proxy_fetch_io.dart' if (dart.library.js_interop) 'proxy_fetch_web.dart'
    as impl;

/// GET a URL the proxy under test serves.
///
/// The mechanism differs per platform (`dart:io`'s HttpClient against the
/// loopback server, the browser's fetch against the Service Worker), so it
/// sits behind this one function. The conformance suite's assertions stay
/// identical for both; only the way the bytes are asked for changes.
Future<({int status, Uint8List body})> proxyGet(
  String url, {
  String? range,
}) =>
    impl.proxyGet(url, range: range);
