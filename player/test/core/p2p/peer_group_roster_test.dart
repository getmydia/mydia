import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/peer_group_roster.dart';
import 'package:player/core/p2p/peer_sync_records.dart';
import 'package:player/core/p2p/peer_sync_store.dart';

void main() {
  late InMemoryPeerSyncStore store;

  setUp(() {
    store = InMemoryPeerSyncStore();
  });

  PeerMember member({
    required String nodeId,
    required String name,
    required String platform,
    bool revoked = false,
  }) {
    return PeerMember(
      nodeId: nodeId,
      deviceName: name,
      platform: platform,
      updatedAt: 1000,
      revoked: revoked,
    );
  }

  test('excludes local node id and revoked members from entries', () async {
    await store.putMember(member(
      nodeId: 'local-node',
      name: 'Local Tablet',
      platform: 'android',
    ));
    await store.putMember(member(
      nodeId: 'peer-active-1',
      name: 'Living Room TV',
      platform: 'android_tv',
    ));
    await store.putMember(member(
      nodeId: 'peer-revoked-2',
      name: 'Old TV Stick',
      platform: 'fire_tv',
      revoked: true,
    ));

    final roster = PeerGroupRoster(
      store: store,
      localNodeId: () => 'local-node',
      isPeerConnected: (_) => false,
    );

    final active = roster.activeMembers();
    expect(active.map((m) => m.nodeId), ['peer-active-1']);

    final entries = await roster.entries();
    expect(entries.length, 1);
    final entry = entries.single;
    expect(entry.id, 'peer-active-1');
    expect(entry.deviceName, 'Living Room TV');
    expect(entry.platform, 'android_tv');
    expect(entry.nodeId, 'peer-active-1');
  });

  test('allows active member and refuses revoked or unknown node', () async {
    await store.putMember(member(
      nodeId: 'local-node',
      name: 'Local Tablet',
      platform: 'android',
    ));
    await store.putMember(member(
      nodeId: 'peer-active-1',
      name: 'Living Room TV',
      platform: 'android_tv',
    ));
    await store.putMember(member(
      nodeId: 'peer-revoked-2',
      name: 'Old TV Stick',
      platform: 'fire_tv',
      revoked: true,
    ));

    final roster = PeerGroupRoster(
      store: store,
      localNodeId: () => 'LOCAL-NODE',
      isPeerConnected: (_) => false,
    );

    expect(await roster.allows('peer-active-1'), isTrue);
    expect(await roster.allows('PEER-ACTIVE-1'), isTrue,
        reason: 'node id lookup should be case-insensitive');
    expect(await roster.allows('peer-revoked-2'), isFalse);
    expect(await roster.allows('local-node'), isFalse);
    expect(await roster.allows('unknown-node'), isFalse);
  });

  test(
      'online entries returns connected active members or all active when none connected',
      () async {
    await store.putMember(member(
      nodeId: 'peer-1',
      name: 'Screen One',
      platform: 'linux',
    ));
    await store.putMember(member(
      nodeId: 'peer-2',
      name: 'Screen Two',
      platform: 'macos',
    ));
    await store.putMember(member(
      nodeId: 'peer-revoked',
      name: 'Screen Revoked',
      platform: 'windows',
      revoked: true,
    ));

    final connectedNodes = <String>{};
    final roster = PeerGroupRoster(
      store: store,
      localNodeId: () => 'my-local-node',
      isPeerConnected: (nodeId) => connectedNodes.contains(nodeId),
    );

    // When none are connected, all active members are returned as fallback.
    final fallbackEntries = await roster.onlineEntries();
    expect(fallbackEntries.map((e) => e.nodeId).toSet(), {'peer-1', 'peer-2'});

    // When peer-2 is connected, only connected active members are returned.
    connectedNodes.add('peer-2');
    // Also mark peer-revoked as connected; it must still be excluded because it is revoked.
    connectedNodes.add('peer-revoked');

    final connectedEntries = await roster.onlineEntries();
    expect(connectedEntries.map((e) => e.nodeId), ['peer-2']);
    expect(connectedEntries.single.deviceName, 'Screen Two');
  });
}
