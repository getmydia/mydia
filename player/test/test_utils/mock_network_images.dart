import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A 1x1 transparent PNG used as the canned response for any image request in
/// widget tests so [CachedNetworkImage] / [NetworkImage] never hit the network.
final Uint8List _transparentPixelPng = Uint8List.fromList(const <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

/// Runs [body] with all HTTP image requests answered by an in-memory
/// transparent PNG. Mirrors the common `network_image_mock` pattern without
/// adding a dependency.
Future<T> mockNetworkImages<T>(Future<T> Function() body) {
  return mockHttpResponse(body, responseBody: _transparentPixelPng);
}

/// Runs [body] with every HTTP request answered from memory.
///
/// Widget tests install a synthetic 400-response client. A readiness test
/// needs to supply its own body (for example, an HLS playlist), without
/// opening a socket or depending on the outside network.
Future<T> mockHttpResponse<T>(
  Future<T> Function() body, {
  required List<int> responseBody,
  int statusCode = HttpStatus.ok,
}) {
  return HttpOverrides.runZoned(
    body,
    createHttpClient: (_) => _MockHttpClient(
      responseBody: responseBody,
      statusCode: statusCode,
    ),
  );
}

class _MockHttpClient implements HttpClient {
  _MockHttpClient({required this.responseBody, required this.statusCode});

  final List<int> responseBody;
  final int statusCode;

  @override
  bool autoUncompress = true;

  @override
  Duration? connectionTimeout;

  @override
  Duration idleTimeout = const Duration(seconds: 15);

  @override
  int? maxConnectionsPerHost;

  @override
  String? userAgent;

  Future<HttpClientRequest> _request() async => _MockHttpClientRequest(
        responseBody: responseBody,
        statusCode: statusCode,
      );

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _request();

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => _request();

  @override
  void close({bool force = false}) {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpClientRequest implements HttpClientRequest {
  _MockHttpClientRequest({
    required this.responseBody,
    required this.statusCode,
  });

  final List<int> responseBody;
  final int statusCode;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  int contentLength = 0;

  @override
  bool persistentConnection = true;

  @override
  final HttpHeaders headers = _MockHttpHeaders();

  @override
  Future<HttpClientResponse> close() async => _MockHttpClientResponse(
        responseBody: responseBody,
        statusCode: statusCode,
      );

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.drain();
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpClientResponse implements HttpClientResponse {
  _MockHttpClientResponse({
    required this.responseBody,
    required this.statusCode,
  });

  final List<int> responseBody;

  @override
  final int statusCode;

  @override
  int get contentLength => responseBody.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  HttpHeaders get headers => _MockHttpHeaders();

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => true;

  @override
  String get reasonPhrase => 'OK';

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(responseBody).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpHeaders implements HttpHeaders {
  @override
  void forEach(void Function(String name, List<String> values) action) {}

  @override
  void set(
    String name,
    Object value, {
    bool preserveHeaderCase = false,
  }) {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
