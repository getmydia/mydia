/// HTTP for third-party sources: one place that turns status codes and
/// transport failures into `SourceException`s.
///
/// No `dart:io` here: this compiles for web too, where sources are off but
/// the code is still built.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/sources/source_error.dart';

class SourceHttp {
  SourceHttp({http.Client? client}) : _client = client ?? http.Client();

  static const defaultTimeout = Duration(seconds: 15);

  final http.Client _client;

  Future<http.Response> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Object? body,
    Duration timeout = defaultTimeout,
    Set<int> passThrough = const {},
  }) async {
    final request = http.Request(method, url)..headers.addAll(headers);
    if (body != null) {
      request.headers.putIfAbsent('Content-Type', () => 'application/json');
      request.body = body is String ? body : jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on SourceException {
      rethrow;
    } catch (_) {
      // Refused, reset, DNS, TLS or timed out: all mean "not reachable this
      // way", and the caller's connection decides what to try next. The
      // exception text is dropped on purpose: it can quote the URL.
      throw const SourceException.unreachable();
    }
    final code = response.statusCode;
    if (code >= 200 && code < 300 || passThrough.contains(code)) {
      return response;
    }
    if (code == 401 || code == 403) throw const SourceException.unauthorized();
    if (code == 404) throw const SourceException.notFound();
    throw SourceException.server('The server answered HTTP $code.');
  }

  Future<Object?> json(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Object? body,
    Duration timeout = defaultTimeout,
    Set<int> passThrough = const {},
  }) async {
    final response = await send(method, url,
        headers: {'Accept': 'application/json', ...headers},
        body: body,
        timeout: timeout,
        passThrough: passThrough);
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const SourceException.server(
          'The server sent a response this app cannot read.');
    }
  }
}
