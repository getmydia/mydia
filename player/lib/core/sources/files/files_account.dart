/// Account ids and stored credentials of files libraries.
///
/// Folders on this device are one account, [kFilesLocalAccountId], whose one
/// server is [kFilesLocalServerId]. Each WebDAV share is its own account,
/// [webDavAccountId], whose server id is the account id and whose first
/// connection is the share's base URL.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

const kFilesLocalAccountId = 'flocal';
const kFilesLocalServerId = 'local';

/// Scheme and host lowercased, the port when given, and the path without a
/// trailing slash, so the same share typed two ways is one account.
String normalizeWebDavUrl(Uri url) {
  final port = url.hasPort ? ':${url.port}' : '';
  var path = url.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  // `Uri.host` drops an IPv6 address's brackets, which the URL needs back.
  final host = url.host.toLowerCase();
  final authority = host.contains(':') ? '[$host]' : host;
  return '${url.scheme.toLowerCase()}://$authority$port$path';
}

/// `w` + the first 16 hex characters of SHA-256 over [normalizeWebDavUrl].
String webDavAccountId(Uri url) =>
    'w${sha256.convert(utf8.encode(normalizeWebDavUrl(url))).toString().substring(0, 16)}';

/// What a WebDAV account stores as its account token (`SourceSecrets`).
class WebDavCredentials {
  const WebDavCredentials({required this.user, required this.password});

  final String user;
  final String password;

  String toJson() => jsonEncode({'user': user, 'password': password});

  /// Throws [FormatException] when [s] is not a stored credential.
  static WebDavCredentials fromJson(String s) {
    final json = jsonDecode(s);
    if (json is! Map ||
        json['user'] is! String ||
        json['password'] is! String) {
      throw const FormatException('Not WebDAV credentials');
    }
    return WebDavCredentials(
      user: json['user'] as String,
      password: json['password'] as String,
    );
  }
}
