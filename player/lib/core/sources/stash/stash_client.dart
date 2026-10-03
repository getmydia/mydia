/// GraphQL over plain HTTP to one Stash server. The API key goes in the
/// `ApiKey` header, never the URL.
library;

import 'dart:convert';

import '../../../domain/sources/source_error.dart';
import '../connection/source_connection.dart';
import '../source_http.dart';
import 'stash_documents.dart';

/// [path] (with its query, if any) under [base], keeping any subpath the
/// server is mounted at behind a reverse proxy. `Uri.resolve` would drop it
/// for a path that starts with `/`. If [path] already starts with the prefix
/// (e.g. server-provided paths), the prefix is not repeated.
Uri stashUnder(Uri base, String path) {
  final prefix = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;

  // Extract just the path without query string to check for prefix
  final pathWithoutQuery = Uri.parse(path).path;

  // If path equals the prefix or starts with '$prefix/', don't prepend
  final needsPrefix = prefix.isEmpty ||
      (pathWithoutQuery != prefix && !pathWithoutQuery.startsWith('$prefix/'));

  final relative = path.startsWith('/') ? path : '/$path';
  final finalPath = needsPrefix ? '$prefix$relative' : relative;

  return Uri.parse('${base.scheme}://${base.authority}$finalPath');
}

class StashClient {
  StashClient({
    required this.connection,
    required SourceHttp http,
    required Future<String?> Function() apiKey,
    void Function()? onUnauthorized,
  })  : _http = http,
        _apiKey = apiKey,
        _onUnauthorized = onUnauthorized;

  final SourceConnection connection;
  final SourceHttp _http;
  final Future<String?> Function() _apiKey;
  final void Function()? _onUnauthorized;

  Future<Map<String, String>> headers() async {
    final key = await _apiKey();
    return {if (key != null && key.isNotEmpty) 'ApiKey': key};
  }

  Future<Uri> url(String path) async =>
      stashUnder(await connection.base(), path);

  Future<Map<String, dynamic>> query(
    String document, [
    Map<String, dynamic> variables = const {},
  ]) async {
    // gqlgen answers a query that fails validation with 400 or 422 and a
    // JSON `errors` body, so those statuses are decoded, not thrown.
    final response = await _guard((base) async => _http.send(
          'POST',
          stashUnder(base, '/graphql'),
          headers: {'Accept': 'application/json', ...await headers()},
          body: {'query': document, 'variables': variables},
          passThrough: const {400, 422},
        ));
    final ok = response.statusCode >= 200 && response.statusCode < 300;
    Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw ok
          ? const SourceException.server(
              'The server sent a response this app cannot read.')
          : SourceException.server(
              'Stash answered HTTP ${response.statusCode}.');
    }
    final errors = json is Map ? json['errors'] : null;
    if (!ok && !(errors is List && errors.isNotEmpty)) {
      throw SourceException.server(
          'Stash answered HTTP ${response.statusCode}.');
    }
    if (json is! Map) {
      throw const SourceException.server('Stash sent an unexpected reply.');
    }
    if (errors is List && errors.isNotEmpty) {
      final message =
          (errors.first is Map ? (errors.first as Map)['message'] : null)
                  ?.toString() ??
              'Stash reported an error.';
      final unsupported = message.contains('Cannot query field') ||
          message.contains('Unknown argument') ||
          message.contains('Unknown type');
      throw unsupported
          ? SourceException.unsupported(message)
          : SourceException.server(message);
    }
    final data = json['data'];
    return data is Map ? data.cast<String, dynamic>() : const {};
  }

  Future<String> text(String path) => _guard((base) async {
        final response = await _http.send('GET', stashUnder(base, path),
            headers: await headers());
        return utf8.decode(response.bodyBytes);
      });

  /// Throws unless Stash reports `OK` (not mid-migration, not unset up).
  Future<void> checkStatus() async {
    final data = await query(stashSystemStatus);
    final status = (data['systemStatus'] as Map?)?['status'];
    if (status != 'OK') {
      throw SourceException.server('Stash reports status $status.');
    }
  }

  Future<T> _guard<T>(Future<T> Function(Uri base) run) async {
    final base = await connection.base();
    try {
      return await run(base);
    } on SourceException catch (e) {
      if (e.kind == SourceErrorKind.unreachable) connection.reportFailure(base);
      if (e.kind == SourceErrorKind.unauthorized) _onUnauthorized?.call();
      rethrow;
    }
  }
}

/// Whether a Stash server answers at [base]. A rejected key still counts as
/// an answer: the server is there, and the next real request reports the
/// key problem.
Future<bool> stashProbe(
  SourceHttp http,
  Uri base,
  Future<String?> Function() apiKey,
) async {
  final key = await apiKey();
  try {
    await http.send(
      'POST',
      stashUnder(base, '/graphql'),
      headers: {if (key != null && key.isNotEmpty) 'ApiKey': key},
      body: {'query': stashSystemStatus},
      timeout: const Duration(seconds: 5),
    );
    return true;
  } on SourceException catch (e) {
    return e.kind != SourceErrorKind.unreachable;
  }
}
