import '../remote/remote_roster.dart';
import 'peer_sync_records.dart';
import 'peer_sync_store.dart';

/// A [DeviceRoster] presenting the local P2P sync peer group.
///
/// Paired peers are allowed to remote-control this player and are offered as
/// remote targets in the player device picker.
class PeerGroupRoster implements DeviceRoster {
  PeerGroupRoster({
    required PeerSyncStore store,
    required String? Function() localNodeId,
    required bool Function(String nodeId) isPeerConnected,
  })  : _store = store,
        _localNodeId = localNodeId,
        _isPeerConnected = isPeerConnected;

  final PeerSyncStore _store;
  final String? Function() _localNodeId;
  final bool Function(String nodeId) _isPeerConnected;

  String? localNodeId() => _localNodeId();

  /// Returns all members in the store excluding the local node and revoked
  /// members.
  List<PeerMember> activeMembers() {
    final local = _localNodeId()?.toLowerCase();
    return [
      for (final member in _store.members().values)
        if (!member.revoked &&
            (local == null || member.nodeId.toLowerCase() != local))
          member,
    ];
  }

  @override
  Future<List<RemoteDeviceEntry>> entries() async {
    return [
      for (final m in activeMembers())
        RemoteDeviceEntry(
          id: m.nodeId,
          deviceName: m.deviceName,
          platform: m.platform,
          nodeId: m.nodeId,
        ),
    ];
  }

  @override
  Future<List<RemoteDeviceEntry>> onlineEntries() async {
    final active = activeMembers();
    // Every active member is swept, the connected ones first: a member that
    // is reachable and playing need not hold a connection yet, and leaving it
    // out would keep its "Playing on" banner away whenever another member is
    // connected.
    final connected = [
      for (final m in active)
        if (_isPeerConnected(m.nodeId)) m,
    ];
    final target = [
      ...connected,
      for (final m in active)
        if (!connected.contains(m)) m,
    ];
    return [
      for (final m in target)
        RemoteDeviceEntry(
          id: m.nodeId,
          deviceName: m.deviceName,
          platform: m.platform,
          nodeId: m.nodeId,
        ),
    ];
  }

  @override
  Future<bool> allows(String peerNodeId) async {
    final local = _localNodeId();
    if (local != null && local.toLowerCase() == peerNodeId.toLowerCase()) {
      return false;
    }
    final direct = _store.member(peerNodeId);
    if (direct != null) {
      return !direct.revoked;
    }
    final wanted = peerNodeId.toLowerCase();
    for (final m in _store.members().values) {
      if (m.nodeId.toLowerCase() == wanted) {
        return !m.revoked;
      }
    }
    return false;
  }
}
