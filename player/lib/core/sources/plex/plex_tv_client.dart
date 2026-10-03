/// plex.tv: PIN sign-in and the account's server list.
library;

import 'package:flutter/foundation.dart';

import '../../../domain/sources/source_error.dart';
import '../source.dart';
import '../source_http.dart';
import 'plex_identity.dart';

@immutable
class PlexPin {
  const PlexPin({required this.id, required this.code});
  final int id;
  final String code;
}

@immutable
class PlexUser {
  const PlexUser({
    required this.uuid,
    required this.username,
    required this.title,
  });
  final String uuid;
  final String username;
  final String title;
}

@immutable
class PlexResource {
  const PlexResource({
    required this.name,
    required this.clientIdentifier,
    required this.owned,
    required this.presence,
    required this.accessToken,
    required this.httpsRequired,
    required this.connections,
  });

  factory PlexResource.fromJson(Map<String, dynamic> json) => PlexResource(
        name: json['name'] as String? ?? 'Plex server',
        clientIdentifier: json['clientIdentifier'] as String,
        owned: json['owned'] as bool? ?? false,
        presence: json['presence'] as bool? ?? false,
        accessToken: json['accessToken'] as String? ?? '',
        httpsRequired: json['httpsRequired'] as bool? ?? false,
        connections: [
          for (final c in json['connections'] as List? ?? const [])
            if ((c as Map)['uri'] is String)
              ServerConnection(
                uri: Uri.parse(c['uri'] as String),
                local: c['local'] as bool? ?? false,
                relay: c['relay'] as bool? ?? false,
              ),
        ],
      );

  final String name;
  final String clientIdentifier;
  final bool owned;
  final bool presence;

  /// The server's own token for this account. Never logged.
  final String accessToken;
  final bool httpsRequired;
  final List<ServerConnection> connections;

  SourceServer toServer({
    required String accountId,
    required String profileId,
  }) =>
      SourceServer(
        id: clientIdentifier,
        accountId: accountId,
        profileId: profileId,
        name: name,
        machineIdentifier: clientIdentifier,
        owned: owned,
        presence: presence,
        httpsRequired: httpsRequired,
        connections: connections,
      );
}

class PlexTvClient {
  PlexTvClient({
    required SourceHttp http,
    required PlexIdentity identity,
    Uri? base,
  })  : _http = http,
        _identity = identity,
        _base = base ?? Uri.parse('https://plex.tv');

  /// Where the viewer types the code. It accepts only the short code a
  /// non-strong PIN produces.
  static const linkUrl = 'https://plex.tv/link';

  final SourceHttp _http;
  final PlexIdentity _identity;
  final Uri _base;

  Future<Map<String, dynamic>> _object(
    String method,
    String path, {
    String? token,
  }) async {
    final json = await _http.json(
      method,
      _base.replace(path: path),
      headers: {
        ..._identity.headers,
        if (token != null) 'X-Plex-Token': token,
      },
    );
    if (json is! Map) {
      throw const SourceException.server('plex.tv sent an unexpected reply.');
    }
    return json.cast<String, dynamic>();
  }

  Future<PlexPin> createPin() async {
    final json = await _object('POST', '/api/v2/pins');
    return PlexPin(id: json['id'] as int, code: json['code'] as String);
  }

  /// The account token once the viewer has approved the code, else null.
  Future<String?> checkPin(int id) async {
    final json = await _object('GET', '/api/v2/pins/$id');
    final token = json['authToken'] as String?;
    return token == null || token.isEmpty ? null : token;
  }

  Future<PlexUser> user(String token) async {
    final json = await _object('GET', '/api/v2/user', token: token);
    final username =
        json['username'] as String? ?? json['email'] as String? ?? '';
    return PlexUser(
      uuid: json['uuid'] as String? ?? '',
      username: username,
      title: json['title'] as String? ?? username,
    );
  }

  /// Every server on the account, owned and shared, whose id this app can
  /// store.
  Future<List<PlexResource>> servers(String token) async {
    final json = await _http.json(
      'GET',
      _base.replace(path: '/api/v2/resources', queryParameters: const {
        'includeHttps': '1',
        'includeRelay': '1',
        'includeIPv6': '1',
      }),
      headers: {..._identity.headers, 'X-Plex-Token': token},
    );
    if (json is! List) {
      throw const SourceException.server('plex.tv sent an unexpected reply.');
    }
    return [
      for (final entry in json)
        if (entry is Map &&
            '${entry['provides']}'.split(',').contains('server') &&
            entry['clientIdentifier'] is String &&
            isValidSourceIdComponent(entry['clientIdentifier'] as String))
          PlexResource.fromJson(entry.cast<String, dynamic>()),
    ];
  }
}

/// [stored] brought up to date with [resources]: names, presence and
/// connections refreshed, servers the account no longer lists marked gone.
/// New servers are not added; the viewer chooses them.
List<SourceServer> reconcilePlexServers(
  List<SourceServer> stored,
  List<PlexResource> resources,
) {
  final byId = {for (final r in resources) r.clientIdentifier: r};
  return [
    for (final server in stored)
      if (byId[server.id] case final resource?)
        server.copyWith(
          name: resource.name,
          presence: resource.presence,
          connections: resource.connections,
          gone: false,
        )
      else
        server.copyWith(gone: true),
  ];
}
