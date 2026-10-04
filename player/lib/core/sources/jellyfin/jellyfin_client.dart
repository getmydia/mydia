/// Authenticated requests to one Jellyfin server, through its current
/// connection. The token goes in the `Authorization` header, never the URL.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../domain/sources/source_error.dart';
import '../connection/source_connection.dart';
import '../source_http.dart';
import 'jellyfin_identity.dart';

/// [path] (with its own query, if any) under [base], keeping a subpath the
/// server is mounted at behind a reverse proxy. [query] is merged over the
/// path's own.
Uri jellyfinUnder(Uri base, String path, [Map<String, String>? query]) {
  final prefix = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  final relative = Uri.parse(path.startsWith('/') ? path : '/$path');
  final merged = {...relative.queryParameters, ...?query};
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: '$prefix${relative.path}',
    queryParameters: merged.isEmpty ? null : merged,
  );
}

/// `/System/Info/Public`: answered without a token.
@immutable
class JellyfinServerInfo {
  const JellyfinServerInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.productName,
    this.localAddress,
  });

  factory JellyfinServerInfo.fromJson(Map<String, dynamic> json) =>
      JellyfinServerInfo(
        id: json['Id'] as String? ?? '',
        name: json['ServerName'] as String? ?? 'Jellyfin',
        version: json['Version'] as String? ?? '',
        productName: json['ProductName'] as String? ?? '',
        localAddress: json['LocalAddress'] as String?,
      );

  final String id;
  final String name;
  final String version;
  final String productName;
  final String? localAddress;

  bool get isJellyfin => productName == 'Jellyfin Server';

  /// 10.9 or newer: `/UserViews?userId=` and `/UserPlayedItems` exist.
  bool get supported {
    final parts = version.split('.').map(int.tryParse).toList();
    if (parts.length < 2 || parts[0] == null || parts[1] == null) {
      return false;
    }
    final (major, minor) = (parts[0]!, parts[1]!);
    return major > 10 || (major == 10 && minor >= 9);
  }
}

Future<JellyfinServerInfo> jellyfinPublicInfo(
  SourceHttp http,
  Uri base, {
  Duration timeout = SourceHttp.defaultTimeout,
}) async {
  final json = await http.json(
      'GET', jellyfinUnder(base, '/System/Info/Public'),
      timeout: timeout);
  if (json is! Map) {
    throw const SourceException.server('This is not a Jellyfin server.');
  }
  return JellyfinServerInfo.fromJson(json.cast<String, dynamic>());
}

/// The server id at [base]. Sends no token, so a probe never hands one to
/// an address that might not be the server it claims.
Future<String?> jellyfinIdentityProbe(
  SourceHttp http,
  Uri base,
  Duration timeout,
) async =>
    (await jellyfinPublicInfo(http, base, timeout: timeout)).id;

class JellyfinClient {
  JellyfinClient({
    required this.connection,
    required SourceHttp http,
    required Future<JellyfinIdentity> Function() identity,
    required Future<String?> Function() token,
    required this.userId,
    void Function()? onUnauthorized,
  })  : _http = http,
        _identity = identity,
        _token = token,
        _onUnauthorized = onUnauthorized;

  final SourceConnection connection;
  final SourceHttp _http;
  final Future<JellyfinIdentity> Function() _identity;
  final Future<String?> Function() _token;
  final void Function()? _onUnauthorized;

  /// Sent as `userId` on every per-user call.
  final String userId;

  Future<JellyfinIdentity> identity() => _identity();

  Future<Map<String, String>> headers() async =>
      {'Authorization': (await _identity()).authorization(await _token())};

  Future<Uri> url(String path, [Map<String, String>? query]) async =>
      jellyfinUnder(await connection.base(), path, query);

  Future<Map<String, dynamic>> get(String path, [Map<String, String>? query]) =>
      _json('GET', path, query, null);

  /// An endpoint that answers a bare JSON array, such as `/Items/Latest`.
  Future<List<Map<String, dynamic>>> getList(String path,
      [Map<String, String>? query]) async {
    final json = await _decoded('GET', path, query, null);
    return [
      for (final m in (json is List ? json : const []))
        if (m is Map) m.cast<String, dynamic>(),
    ];
  }

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, String>? query,
    Object? body,
  }) =>
      _json('POST', path, query, body);

  /// A call whose answer does not matter beyond its status.
  Future<void> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) =>
      _send(method, path, query, body);

  Future<String> text(String path) async =>
      utf8.decode((await _send('GET', path, null, null)).bodyBytes);

  Future<Map<String, dynamic>> _json(
    String method,
    String path,
    Map<String, String>? query,
    Object? body,
  ) async {
    final json = await _decoded(method, path, query, body);
    return json is Map ? json.cast<String, dynamic>() : const {};
  }

  Future<Object?> _decoded(
    String method,
    String path,
    Map<String, String>? query,
    Object? body,
  ) async {
    final response = await _send(method, path, query, body);
    if (response.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const SourceException.server(
          'The Jellyfin server sent a response this app cannot read.');
    }
  }

  Future<http.Response> _send(
    String method,
    String path,
    Map<String, String>? query,
    Object? body,
  ) async {
    final base = await connection.base();
    try {
      return await _http.send(method, jellyfinUnder(base, path, query),
          headers: {'Accept': 'application/json', ...await headers()},
          body: body);
    } on SourceException catch (e) {
      if (e.kind == SourceErrorKind.unreachable) connection.reportFailure(base);
      if (e.kind == SourceErrorKind.unauthorized) _onUnauthorized?.call();
      rethrow;
    }
  }
}
