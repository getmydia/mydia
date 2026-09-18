/// Which kind of network path playback bytes take to the server.
///
/// A stall is remembered per path, not per server, because one server can be
/// reached over very different links: a relayed p2p path can be far slower
/// than the direct one that replaces it a minute later.
library;

import '../p2p/p2p_service.dart' show P2pConnectionType;

enum LinkPath { direct, relay, mixed, http }

/// The path playback is on, or null while a p2p connection has no peer path
/// yet. Plain HTTP is always [LinkPath.http].
LinkPath? linkPathFor({
  required bool isP2P,
  required P2pConnectionType type,
}) {
  if (!isP2P) return LinkPath.http;
  return switch (type) {
    P2pConnectionType.direct => LinkPath.direct,
    P2pConnectionType.relay => LinkPath.relay,
    P2pConnectionType.mixed => LinkPath.mixed,
    P2pConnectionType.none => null,
  };
}
