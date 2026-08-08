import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// GET [url] with the browser's own fetch, so the request passes through the
/// Service Worker exactly as a media element's would.
Future<({int status, Uint8List body})> proxyGet(
  String url, {
  String? range,
}) async {
  final headers = range == null ? const <String, String>{} : {'range': range};

  final response = await web.window
      .fetch(
        url.toJS,
        web.RequestInit(
          method: 'GET',
          headers: headers.jsify() as web.HeadersInit,
          // The worker's response must be the one under test, never a copy the
          // HTTP cache kept from an earlier case in this same file.
          cache: 'no-store',
        ),
      )
      .toDart;

  final buffer = await response.arrayBuffer().toDart;
  return (status: response.status, body: buffer.toDart.asUint8List());
}
