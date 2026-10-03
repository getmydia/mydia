/// Signing in to a Jellyfin server: Quick Connect (approve a code from a
/// client already signed in) or username and password. Nothing here holds
/// a token yet, so it talks to a fixed base, not a connection.
library;

import 'package:flutter/foundation.dart';

import '../../../domain/sources/source_error.dart';
import '../source_http.dart';
import 'jellyfin_client.dart';
import 'jellyfin_identity.dart';

@immutable
class JellyfinSession {
  const JellyfinSession({
    required this.accessToken,
    required this.userId,
    required this.userName,
    required this.isAdmin,
  });

  factory JellyfinSession.fromJson(Map<String, dynamic> json) {
    final user = (json['User'] as Map?)?.cast<String, dynamic>() ?? const {};
    final token = json['AccessToken'] as String?;
    final id = user['Id'] as String?;
    if (token == null || token.isEmpty || id == null || id.isEmpty) {
      throw const SourceException.server(
          'Jellyfin signed you in but sent no session.');
    }
    return JellyfinSession(
      accessToken: token,
      userId: id,
      userName: user['Name'] as String? ?? 'Jellyfin',
      isAdmin: (user['Policy'] as Map?)?['IsAdministrator'] == true,
    );
  }

  final String accessToken;
  final String userId;
  final String userName;
  final bool isAdmin;
}

@immutable
class QuickConnectCode {
  const QuickConnectCode({required this.code, required this.secret});
  final String code;
  final String secret;
}

class JellyfinAuth {
  JellyfinAuth({
    required SourceHttp http,
    required this.base,
    required this.identity,
  }) : _http = http;

  final SourceHttp _http;
  final Uri base;
  final JellyfinIdentity identity;

  Map<String, String> get _headers =>
      {'Authorization': identity.authorization()};

  Future<Object?> _call(String method, String path,
          {Map<String, String>? query, Object? body}) =>
      _http.json(method, jellyfinUnder(base, path, query),
          headers: _headers, body: body);

  /// False when the server says so or cannot say: the password form is
  /// always there to fall back to.
  Future<bool> quickConnectEnabled() async {
    try {
      return await _call('GET', '/QuickConnect/Enabled') == true;
    } on SourceException {
      return false;
    }
  }

  Future<QuickConnectCode> initiateQuickConnect() async {
    final json = await _call('POST', '/QuickConnect/Initiate');
    final code = json is Map ? json['Code'] as String? : null;
    final secret = json is Map ? json['Secret'] as String? : null;
    if (code == null || secret == null) {
      throw const SourceException.server(
          'Jellyfin did not hand out a Quick Connect code.');
    }
    return QuickConnectCode(code: code, secret: secret);
  }

  /// Throws `SourceException.notFound()` once the code has expired.
  Future<bool> quickConnectApproved(String secret) async {
    final json =
        await _call('GET', '/QuickConnect/Connect', query: {'secret': secret});
    return json is Map && json['Authenticated'] == true;
  }

  Future<JellyfinSession> withQuickConnect(String secret) async =>
      _session(await _call('POST', '/Users/AuthenticateWithQuickConnect',
          body: {'Secret': secret}));

  Future<JellyfinSession> withPassword(
          String username, String password) async =>
      _session(await _call('POST', '/Users/AuthenticateByName',
          body: {'Username': username, 'Pw': password}));

  JellyfinSession _session(Object? json) => json is Map
      ? JellyfinSession.fromJson(json.cast<String, dynamic>())
      : throw const SourceException.server(
          'Jellyfin sent an unexpected sign-in reply.');
}
