/// The ways to reach a Jellyfin server: the URL the viewer entered, and the
/// LAN address the server advertises, used when it answers.
library;

import '../connection/racing_connection.dart';
import '../connection/source_connection.dart';
import '../source.dart';

List<ServerConnection> jellyfinConnections(Uri entered, String? localAddress) {
  final local = localAddress == null ? null : Uri.tryParse(localAddress);
  final useLocal = local != null &&
      local.host.isNotEmpty &&
      (local.scheme == 'http' || local.scheme == 'https') &&
      isPrivateHost(local.host) &&
      local != entered;
  return [
    ServerConnection(uri: entered, local: isPrivateHost(entered.host)),
    if (useLocal) ServerConnection(uri: local, local: true),
  ];
}

/// HTTPS anywhere, plain HTTP only to a private host; LAN first. The add
/// flow already refused plain HTTP to a public host, so this only guards
/// against a record from elsewhere.
List<ServerConnection> rankJellyfinConnections(List<ServerConnection> all) =>
    all
        .where((c) => c.uri.scheme == 'https' || isPrivateHost(c.uri.host))
        .toList()
      ..sort((a, b) => connectionRank(a).compareTo(connectionRank(b)));
