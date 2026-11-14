import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:player/core/backup/backup_identity.dart';
import 'package:player/core/backup/backup_meta_store.dart';
import 'package:player/core/backup/backup_snapshot.dart';
import 'package:player/core/backup/backup_sync_service.dart';
import 'package:player/core/backup/backup_vault_state.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../test_utils/mock_auth_storage.dart';
import '../backup/fake_backup_relay.dart';
import 'peer_sync_service_test.dart'
    show FakePeerSyncNetwork, FakePeerSyncTransport, FakeRelayClient, TestClock;

/// One install: p2p pairing and the cloud backup over the same stores, wired
/// the way `backupPairingHooksProvider` wires them.
class _Node {
  _Node(this.name, this.nodeId, this.net) {
    transport =
        FakePeerSyncTransport(network: net.network, localNodeId: nodeId);
    snapshot = BackupSnapshot(
      peerSync: store,
      authStorage: auth,
      meta: meta,
      loadSources: sources.load,
      putAccount: sources.putAccount,
      settings: SettingsService(storage: auth),
      loadSubtitleLanguages: () async => null,
      saveSubtitleLanguages: (_) async {},
      onRemoteFilesChanges: (_, __) async {},
      rootsFor: (_) async => const [],
      putRoots: (_, __) async {},
    );
    backup = BackupSyncService(
      relay: net.backupRelay.relayClient(),
      authStorage: auth,
      meta: meta,
      snapshot: snapshot,
      deviceName: () async => name,
      platform: 'linux',
      localNodeId: () => nodeId,
      delay: (d) async {
        delays.add(d);
        await onDelay?.call();
      },
    );
    peers = PeerSyncService(
      store: store,
      authStorage: auth,
      transport: transport,
      relayClient: net.claimRelay,
      deviceName: name,
      platform: 'linux',
      resolveDeviceName: () async => name,
      clock: net.clock.call,
      backupKeysForPair: () => keysForPair(),
      onJoinerBackupKeys: (node, signer, box) =>
          backup.addMemberForPair(signer, box, nodeId: node),
      onJoinedVault: backup.adoptVault,
      onPeerRevoked: backup.removeMemberForNode,
    );
  }

  final String name;
  final String nodeId;
  final _Net net;
  final auth = MockAuthStorage();
  final store = InMemoryPeerSyncStore();
  final sources = InMemorySourceStore();
  final meta = BackupMetaStore(InMemoryBackupMetaStorage());
  late final FakePeerSyncTransport transport;
  late final BackupSnapshot snapshot;
  late final BackupSyncService backup;
  late final PeerSyncService peers;
  final delays = <Duration>[];
  Future<void> Function()? onDelay;
  late Future<({String signer, String box})?> Function() keysForPair =
      backup.pairKeys;

  Future<void> start() async {
    await peers.start();
    await backup.start();
  }

  Future<void> enableBackup() async =>
      backup.confirmEnable(await backup.prepareEnable());

  Future<String> slotId() async =>
      (await BackupIdentity.loadOrCreate(auth)).slotId;

  Future<BackupVaultState?> state() => BackupVaultStateStore(auth).load();

  void dispose() {
    peers.dispose();
    backup.dispose();
    transport.dispose();
  }
}

class _Net {
  final network = FakePeerSyncNetwork();
  final claimRelay = FakeRelayClient();
  final backupRelay = FakeBackupRelay();
  final clock = TestClock();
  final nodes = <_Node>[];

  Future<_Node> node(String name, String nodeId) async {
    final n = _Node(name, nodeId, this);
    nodes.add(n);
    await n.start();
    return n;
  }

  Future<void> pair(_Node host, _Node joiner) async {
    final offer = await host.peers.startPairingOffer();
    await joiner.peers.pairWithCode(offer.code);
  }

  void dispose() {
    for (final n in nodes) {
      n.dispose();
    }
  }
}

void main() {
  late _Net net;
  setUp(() => net = _Net());
  tearDown(() => net.dispose());

  test('a joiner without backup joins the host vault', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    final vaultId = (await host.state())!.vaultId;

    await net.pair(host, joiner);

    expect(joiner.peers.isPaired, isTrue);
    expect(joiner.backup.enabled, isTrue);
    expect((await joiner.state())!.vaultId, vaultId);
    expect(joiner.backup.status.value, isA<BackupIdle>());
    expect(joiner.backup.showJoinedNotice, isTrue);
    expect(joiner.backup.recoveryKeyText, isNull,
        reason: 'the recovery key never travels over pairing');
    final vault = net.backupRelay.vault(vaultId);
    final joinerSlot = await joiner.slotId();
    expect(vault.members.values.map((m) => m.slotId), contains(joinerSlot));
    expect(vault.epoch, 1, reason: 'joining does not rotate');
    expect(net.backupRelay.slotWrites[joinerSlot], 1);
    expect(host.meta.nodeToSlot()['node-b'], joinerSlot);
    // The host's own mapping comes over in its group record, which its
    // next upload carries (the group did not exist when it enabled backup).
    await host.backup.flush();
    await joiner.backup.poll();
    expect(joiner.meta.nodeToSlot()['node-a'], await host.slotId());
    expect(joiner.meta.nodeToSlot()['node-b'], joinerSlot);

    joiner.backup.acknowledgeJoinedNotice();
    expect(joiner.backup.showJoinedNotice, isFalse);
  });

  test('a host without backup sends no vault and the joiner stays off',
      () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');

    await net.pair(host, joiner);

    expect(joiner.peers.isPaired, isTrue);
    expect(joiner.backup.enabled, isFalse);
    expect(joiner.backup.status.value, isA<BackupOff>());
    expect(joiner.backup.showJoinedNotice, isFalse);
    expect(net.backupRelay.vaults, isEmpty);
  });

  test('a relay failure on the host still pairs, without backup', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    net.backupRelay.override = (r) => r.url.path.endsWith('/members')
        ? http.Response('{"error":"server"}', 500)
        : null;

    await net.pair(host, joiner);

    expect(joiner.peers.isPaired, isTrue);
    expect(joiner.backup.enabled, isFalse);
    expect(host.meta.nodeToSlot().containsKey('node-b'), isFalse);
  });

  test('a joiner whose keys cannot be made still pairs', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    joiner.keysForPair = () async => throw StateError('keyring refused');

    await net.pair(host, joiner);

    expect(joiner.peers.isPaired, isTrue);
    expect(joiner.backup.enabled, isFalse);
    expect(net.backupRelay.onlyVault.members, hasLength(2));
  });

  test('revoking the joiner on the host removes it and rotates', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    await net.pair(host, joiner);
    final joinerSlot = await joiner.slotId();
    final vault = net.backupRelay.onlyVault;
    expect(vault.slots.containsKey(joinerSlot), isTrue);

    net.clock.setMs(5000);
    await host.peers.revokePeer('node-b');

    expect(host.store.member('node-b')!.revoked, isTrue);
    expect(vault.epoch, 2);
    expect(
        vault.members.values.map((m) => m.slotId), isNot(contains(joinerSlot)));
    expect(vault.slots.containsKey(joinerSlot), isFalse);
    expect((await host.state())!.epoch, 2);

    await joiner.backup.poll();
    expect(joiner.backup.status.value, isA<BackupRemoved>());
  });

  test('revoking a peer that never joined the vault leaves it alone', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await net.pair(host, joiner);
    await host.enableBackup();
    final before = net.backupRelay.requests.length;

    await host.peers.revokePeer('node-b');

    expect(host.store.member('node-b')!.revoked, isTrue);
    expect(net.backupRelay.onlyVault.epoch, 1);
    expect(net.backupRelay.requests.skip(before), isEmpty);
  });

  test('a device revokes a peer it learned of from the group record', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final laptop = await net.node('Night Harbor Laptop', 'node-b');
    final phone = await net.node('Pocket Phone', 'node-c');
    await host.enableBackup();
    await net.pair(host, laptop);
    await net.pair(host, phone);
    expect(laptop.meta.nodeToSlot().containsKey('node-c'), isFalse);

    // The host's slot now carries node-c's slot; the laptop merges it.
    host.backup.markDirty();
    await host.backup.flush();
    await laptop.backup.poll();
    final phoneSlot = await phone.slotId();
    expect(laptop.meta.nodeToSlot()['node-c'], phoneSlot);

    await laptop.peers.revokePeer('node-c');
    final vault = net.backupRelay.onlyVault;
    expect(vault.epoch, 2);
    expect(vault.slots.containsKey(phoneSlot), isFalse);
  });

  test('leaving the p2p group keeps this device in the vault', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    await net.pair(host, joiner);
    final vault = net.backupRelay.onlyVault;

    await joiner.peers.leaveGroup();

    expect(joiner.peers.groupId, isNull);
    expect(joiner.backup.enabled, isTrue);
    expect(vault.slots.containsKey(await joiner.slotId()), isTrue);
    expect(vault.epoch, 1);
  });

  test('a joiner with its own vault is asked, not switched', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    await joiner.enableBackup();
    final hostVault = (await host.state())!.vaultId;
    final ownVault = (await joiner.state())!.vaultId;

    await net.pair(host, joiner);

    expect(joiner.peers.isPaired, isTrue);
    expect((await joiner.state())!.vaultId, ownVault);
    expect(joiner.backup.pendingVaultChoice.value,
        (current: ownVault, offered: hostVault));
    expect(joiner.backup.showJoinedNotice, isFalse);
  });

  test('keeping the offered vault switches and deletes a sole-member vault',
      () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    await joiner.enableBackup();
    final hostVault = (await host.state())!.vaultId;
    final ownVault = (await joiner.state())!.vaultId;
    await net.pair(host, joiner);

    await joiner.backup.resolveVaultChoice(keepOffered: true);

    expect(joiner.backup.pendingVaultChoice.value, isNull);
    final state = (await joiner.state())!;
    expect(state.vaultId, hostVault);
    expect(state.recoveryKeyText, isNull);
    expect(net.backupRelay.vaults.containsKey(ownVault), isFalse);
    expect(
        net.backupRelay
            .vault(hostVault)
            .slots
            .containsKey(await joiner.slotId()),
        isTrue);
    expect(joiner.backup.status.value, isA<BackupIdle>());
  });

  test('keeping the current vault leaves both as they were', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    await joiner.enableBackup();
    final ownVault = (await joiner.state())!.vaultId;
    await net.pair(host, joiner);

    await joiner.backup.resolveVaultChoice(keepOffered: false);

    expect(joiner.backup.pendingVaultChoice.value, isNull);
    expect((await joiner.state())!.vaultId, ownVault);
    expect(net.backupRelay.vaults, hasLength(2));
  });

  test('adoptVault waits for the host add that races the reply', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    final vaultId = (await host.state())!.vaultId;
    final keys = (await joiner.backup.pairKeys())!;
    joiner.onDelay = () async {
      joiner.onDelay = null;
      await host.backup.addMemberForPair(keys.signer, keys.box);
    };

    await joiner.backup.adoptVault(vaultId);

    expect(joiner.delays, hasLength(1));
    expect(joiner.backup.enabled, isTrue);
    expect(joiner.backup.showJoinedNotice, isTrue);
  });

  test('adoptVault gives up after three retries', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    final vaultId = (await host.state())!.vaultId;

    await expectLater(joiner.backup.adoptVault(vaultId), throwsA(anything));

    expect(joiner.delays, hasLength(3));
    expect(joiner.backup.enabled, isFalse);
    expect(await joiner.state(), isNull);
  });

  test('the joined notice survives a restart', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    await net.pair(host, joiner);

    final again = BackupSyncService(
      relay: net.backupRelay.relayClient(),
      authStorage: joiner.auth,
      meta: joiner.meta,
      snapshot: joiner.snapshot,
      deviceName: () async => joiner.name,
      platform: 'linux',
    );
    addTearDown(again.dispose);
    expect(again.showJoinedNotice, isTrue);
    again.acknowledgeJoinedNotice();
    expect(joiner.meta.joinedNoticePending, isFalse);
  });
}
