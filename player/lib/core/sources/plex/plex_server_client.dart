/// Authenticated requests to one Plex server, through its current
/// connection. The token goes in a header, never the URL.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../domain/sources/source_error.dart';
import '../connection/source_connection.dart';
import '../source_http.dart';
import 'plex_identity.dart';

class PlexServerClient {
  PlexServerClient({
    required this.connection,
    required SourceHttp http,
    required Future<PlexIdentity> Function() identity,
    required Future<String?> Function() token,
    void Function()? onUnauthorized,
  })  : _http = http,
        _identity = identity,
        _token = token,
        _onUnauthorized = onUnauthorized;

  final SourceConnection connection;
  final SourceHttp _http;
  final Future<PlexIdentity> Function() _identity;
  final Future<String?> Function() _token;
  final void Function()? _onUnauthorized;

  Future<Map<String, String>> headers() async {
    final identity = await _identity();
    final token = await _token();
    return {
      ...identity.headers,
      if (token != null && token.isNotEmpty) 'X-Plex-Token': token,
    };
  }

  /// [headers] as query parameters, for a cast receiver that cannot send
  /// headers. Plex reads every `X-Plex-*` parameter from the query too.
  Future<Map<String, String>> receiverQuery() => headers();

  /// [path] may carry its own query; [query] is merged over it.
  Future<Uri> url(String path, [Map<String, String>? query]) async =>
      _resolve(await connection.base(), path, query);

  static Uri _resolve(Uri base, String path, Map<String, String>? query) {
    final relative = Uri.parse(path);
    final merged = {...relative.queryParameters, ...?query};
    return base.resolveUri(Uri(
      path: relative.path,
      queryParameters: merged.isEmpty ? null : merged,
    ));
  }

  /// The `MediaContainer` object of a JSON response.
  Future<Map<String, dynamic>> container(
    String path, [
    Map<String, String>? query,
  ]) async {
    // Guids are what All servers matches copies of a title on.
    final response = await _send('GET', path, {'includeGuids': '1', ...?query});
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const SourceException.server(
          'The Plex server sent a response this app cannot read.');
    }
    final body = json is Map ? json['MediaContainer'] : null;
    return body is Map ? body.cast<String, dynamic>() : const {};
  }

  Future<String> text(String path) async =>
      utf8.decode((await _send('GET', path, null)).bodyBytes);

  /// A request whose answer does not matter beyond its status: timeline,
  /// scrobble, transcode stop.
  Future<void> ping(String path, [Map<String, String>? query]) =>
      _send('GET', path, query);

  /// A PUT whose answer does not matter beyond its status.
  Future<void> put(String path, [Map<String, String>? query]) =>
      _send('PUT', path, query);

  Future<http.Response> _send(
    String method,
    String path,
    Map<String, String>? query,
  ) async {
    final base = await connection.base();
    try {
      return await _http.send(method, _resolve(base, path, query),
          headers: await headers());
    } on SourceException catch (e) {
      if (e.kind == SourceErrorKind.unreachable) connection.reportFailure(base);
      if (e.kind == SourceErrorKind.unauthorized) _onUnauthorized?.call();
      rethrow;
    }
  }
}

/// The `machineIdentifier` the server at [base] reports. `/identity` needs
/// no token, so a probe never sends one to an address that might not be
/// the server it claims.
Future<String?> plexIdentityProbe(
  SourceHttp http,
  Uri base,
  Duration timeout,
) async {
  final json =
      await http.json('GET', base.resolve('/identity'), timeout: timeout);
  final body = json is Map ? json['MediaContainer'] : null;
  return body is Map ? body['machineIdentifier'] as String? : null;
}
