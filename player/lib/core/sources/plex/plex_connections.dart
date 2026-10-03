/// Which of a Plex server's advertised connections the player may use, in
/// preference order.
library;

import '../connection/racing_connection.dart';
import '../connection/source_connection.dart';
import '../source.dart';

/// [all] in preference order, without plain HTTP except on the LAN, and
/// not even there when the server requires HTTPS.
List<ServerConnection> rankPlexConnections(
  List<ServerConnection> all, {
  required bool allowInsecureLocal,
}) =>
    all
        .where((c) =>
            c.uri.scheme == 'https' ||
            // plex.tv's `local` flag is only a claim: a plain HTTP candidate
            // must also be a private address.
            (c.local &&
                !c.relay &&
                allowInsecureLocal &&
                isPrivateHost(c.uri.host)))
        .toList()
      ..sort((a, b) => connectionRank(a).compareTo(connectionRank(b)));
