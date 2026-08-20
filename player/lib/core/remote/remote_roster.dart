import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:graphql_flutter/graphql_flutter.dart';

/// How long a fetched roster is treated as current.
const _rosterTtl = Duration(minutes: 15);

/// Floor between refetches triggered by an unrecognized peer.
///
/// Without this, anyone who can dial this node can make it query the server
/// as fast as they can open connections.
const _unknownPeerThrottle = Duration(minutes: 1);

@immutable
class RemoteDeviceEntry {
  final String id;
  final String deviceName;
  final String platform;
  final String nodeId;

  const RemoteDeviceEntry({
    required this.id,
    required this.deviceName,
    required this.platform,
    required this.nodeId,
  });
}

/// The devices on this account, and the answer to "may this peer drive me?".
///
/// One source for both questions on purpose. The controller reads it as a
/// picker list and the target reads it as an access control list, so the two
/// cannot drift apart.
class RemoteRoster {
  final GraphQLClient _client;
  final DateTime Function() _now;

  List<RemoteDeviceEntry> _entries = const [];
  DateTime? _fetchedAt;
  DateTime? _lastUnknownPeerFetch;

  RemoteRoster({
    required GraphQLClient client,
    DateTime Function()? now,
  })  : _client = client,
        _now = now ?? DateTime.now;

  static const _query = r'''
    query Devices {
      devices {
        __typename
        id
        deviceName
        platform
        nodeId
      }
    }
  ''';

  /// Devices that can actually be dialed. A device with no node ID has never
  /// reported one, so it is omitted rather than listed as permanently
  /// offline.
  Future<List<RemoteDeviceEntry>> entries() async {
    await _ensureFresh();
    return _entries;
  }

  /// Whether a dialing peer is one of this account's devices.
  ///
  /// The peer node ID is authenticated by iroh during the QUIC handshake, so
  /// this is a membership test rather than a credential check.
  Future<bool> allows(String peerNodeId) async {
    final justFetched = await _ensureFresh();
    if (_entries.any((e) => e.nodeId == peerNodeId)) return true;

    if (justFetched) {
      // _ensureFresh had never fetched, or the roster had gone stale, so it
      // just fetched the freshest possible answer itself. Arm the throttle
      // anyway, so a burst of unknown peers right behind this one doesn't
      // each pay for a pointless repeat fetch.
      _lastUnknownPeerFetch = _now();
      return false;
    }

    // An unknown peer might be a device paired since the last fetch, so it
    // is worth one throttled refetch before refusing. The timestamp is
    // recorded before the refetch runs, not after, so a failed refetch still
    // arms the throttle instead of leaving it wide open for retries.
    if (_canRefetchForUnknownPeer()) {
      _lastUnknownPeerFetch = _now();
      await refresh();
      return _entries.any((e) => e.nodeId == peerNodeId);
    }

    return false;
  }

  bool _canRefetchForUnknownPeer() {
    final last = _lastUnknownPeerFetch;
    if (last == null) return true;
    return _now().difference(last) >= _unknownPeerThrottle;
  }

  /// Fetches the roster if it is missing or stale. Returns whether a fetch
  /// happened, so [allows] can avoid redundantly repeating it moments later.
  Future<bool> _ensureFresh() async {
    final fetchedAt = _fetchedAt;
    if (fetchedAt != null && _now().difference(fetchedAt) < _rosterTtl) {
      return false;
    }
    await refresh();
    return true;
  }

  /// Fetches the roster. Leaves the previous entries in place on failure, so
  /// a momentary server blip does not lock out every controller.
  Future<void> refresh() async {
    try {
      final result = await _client.query(
        QueryOptions(document: gql(_query), fetchPolicy: FetchPolicy.noCache),
      );

      if (result.hasException) {
        debugPrint('[RemoteRoster] refresh failed: ${result.exception}');
        return;
      }

      final devices = (result.data?['devices'] as List?) ?? const [];
      _entries = devices
          .cast<Map<String, dynamic>>()
          .where((d) => (d['nodeId'] as String?)?.isNotEmpty ?? false)
          .map((d) => RemoteDeviceEntry(
                id: d['id'] as String,
                deviceName: d['deviceName'] as String,
                platform: d['platform'] as String,
                nodeId: d['nodeId'] as String,
              ))
          .toList(growable: false);
      _fetchedAt = _now();
    } catch (error) {
      debugPrint('[RemoteRoster] refresh threw: $error');
    }
  }
}
