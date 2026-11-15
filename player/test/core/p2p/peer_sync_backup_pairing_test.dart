import 'dart:async';

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
      clock: () => clockOverride ?? DateTime.now(),
      localNodeId: () => reportsNode ? nodeId : null,
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
      onJoinerBackupKeys: (node, signer, box, deadline) => backup
          .addMemberForPair(signer, box, nodeId: node, deadline: deadline),
      onJoinedVault: backup.adoptVault,
      onPeerRevoked: (node, name) =>
          backup.notePeerRevoked(node, deviceName: name),
      backupHookTimeout: net.hookTimeout,
    );
  }

  /// When false the backup does not know this device's node id, so its
  /// group record carries only what the test put in [meta].
  bool reportsNode = true;

  /// When set, the backup's clock: lets a test move past a deadline at the
  /// exact point it means to.
  DateTime? clockOverride;

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
  Duration hookTimeout = PeerSyncService.backupAdmitTimeout;

  Future<_Node> node(String name, String nodeId) async {
    final n = _Node(name, nodeId, this);
    nodes.add(n);
    await n.start();
    return n;
  }

  Future<void> pair(_Node host, _Node joiner) async {
    final offer = await host.peers.startPairingOffer();
    await joiner.peers.pairWithCode(offer.code);
    // The joiner's first upload and merge run after pairing returns.
    await joiner.backup.settled();
  }

  /// Uploads [n]'s current records now.
  Future<void> upload(_Node n) async {
    n.backup.markDirty();
    await n.backup.flush();
  }

  void dispose() {
    backupRelay.releaseHung();
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
    // The host's own node comes over as its slot's claim, in the group
    // record its next upload carries (the group did not exist when it
    // enabled backup).
    await host.backup.flush();
    await joiner.backup.poll();
    expect(joiner.meta.slotClaims()[await host.slotId()], {'node-a'});
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

  test('revoking the joiner records a pending removal and writes nothing',
      () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    await net.pair(host, joiner);
    await host.backup.poll();
    final joinerSlot = await joiner.slotId();
    final vault = net.backupRelay.onlyVault;
    final before = net.backupRelay.requests.length;

    net.clock.setMs(5000);
    await host.peers.revokePeer('node-b');

    expect(host.store.member('node-b')!.revoked, isTrue);
    expect(net.backupRelay.requests.skip(before), isEmpty);
    expect(vault.epoch, 1);
    expect(host.meta.pendingRemovals()['node-b']?.slotId, joinerSlot);
    final pending = host.backup.pendingRemovals.value.single;
    expect(pending.slotId, joinerSlot);
    expect(pending.deviceName, 'Night Harbor Laptop');

    // The viewer removes it: a rotation that also replaces the recovery
    // key, and the entry clears.
    final key = await host.backup.removeMember(pending.slotId);
    expect(vault.epoch, 2);
    expect(vault.slots.containsKey(joinerSlot), isFalse);
    expect((await host.state())!.recoveryKeyText, key.display);
    expect(host.backup.pendingRemovals.value, isEmpty);
    expect(host.meta.pendingRemovals(), isEmpty);

    await joiner.backup.poll();
    expect(joiner.backup.status.value, isA<BackupRemoved>());
  });

  test('a pending removal clears once another device removed the slot',
      () async {
    final host = await net.node('Living Room TV', 'node-a');
    final laptop = await net.node('Night Harbor Laptop', 'node-b');
    final phone = await net.node('Pocket Phone', 'node-c');
    await host.enableBackup();
    await net.pair(host, laptop);
    await net.pair(host, phone);
    await host.backup.poll();
    await host.peers.revokePeer('node-b');
    expect(host.backup.pendingRemovals.value, hasLength(1));

    await phone.backup.poll();
    await phone.backup.removeMember(await laptop.slotId());
    await host.backup.poll();

    expect(host.backup.pendingRemovals.value, isEmpty);
    expect(host.meta.pendingRemovals(), isEmpty);
  });

  test('pending removals are forgotten when backup is turned off', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    await net.pair(host, joiner);
    await host.peers.revokePeer('node-b');
    expect(host.meta.pendingRemovals(), isNotEmpty);

    await host.backup.disable();

    expect(host.meta.pendingRemovals(), isEmpty);
    expect(host.backup.pendingRemovals.value, isEmpty);
  });

  test('revoking a peer that never joined the vault leaves it alone', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await net.pair(host, joiner);
    await host.enableBackup();
    final before = net.backupRelay.requests.length;

    await host.peers.revokePeer('node-b');

    expect(host.store.member('node-b')!.revoked, isTrue);
    expect(net.backupRelay.requests.skip(before), isEmpty);
    await host.backup.poll();
    expect(host.backup.pendingRemovals.value, isEmpty);
    expect(net.backupRelay.onlyVault.epoch, 1);
  });

  test('a device flags a peer that claims its node in its own slot', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final laptop = await net.node('Night Harbor Laptop', 'node-b');
    final phone = await net.node('Pocket Phone', 'node-c');
    await host.enableBackup();
    await net.pair(host, laptop);
    await net.pair(host, phone);
    expect(laptop.meta.nodeToSlot().containsKey('node-c'), isFalse);

    // The phone's first upload says node-c is its own; the laptop merges it.
    await laptop.backup.poll();
    final phoneSlot = await phone.slotId();
    expect(laptop.meta.slotClaims()[phoneSlot], {'node-c'});

    await laptop.peers.revokePeer('node-c');
    expect(laptop.backup.pendingRemovals.value.single.slotId, phoneSlot);
    expect(net.backupRelay.onlyVault.epoch, 1);
  });

  test('a member cannot aim a revocation at another member slot', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final laptop = await net.node('Night Harbor Laptop', 'node-b');
    final phone = await net.node('Pocket Phone', 'node-c');
    await host.enableBackup();
    await net.pair(host, laptop);
    await net.pair(host, phone);
    final hostSlot = await host.slotId();
    final laptopSlot = await laptop.slotId();

    // The laptop uploads a group record saying its node is the host's slot.
    laptop.reportsNode = false;
    await laptop.meta.setNodeToSlot('node-b', hostSlot);
    await net.upload(laptop);
    await phone.backup.poll();
    expect(phone.meta.slotClaims()[laptopSlot] ?? const <String>{},
        isNot(contains('node-b')));

    await phone.peers.revokePeer('node-b');

    expect(phone.backup.pendingRemovals.value, isEmpty,
        reason: 'no claim the phone believes names it');
    expect(net.backupRelay.onlyVault.epoch, 1);
  });

  test('a node two slots claim is not flagged', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final laptop = await net.node('Night Harbor Laptop', 'node-b');
    final phone = await net.node('Pocket Phone', 'node-c');
    await host.enableBackup();
    await net.pair(host, laptop);
    await net.pair(host, phone);

    // The phone claims the laptop's node for its own slot.
    await phone.meta.setNodeToSlot('node-b', await phone.slotId());
    await net.upload(phone);
    await host.backup.poll();

    await host.peers.revokePeer('node-b');

    expect(host.store.member('node-b')!.revoked, isTrue);
    expect(host.backup.pendingRemovals.value, isEmpty);
    expect(net.backupRelay.onlyVault.epoch, 1);
  });
  test('a signer already in the vault is not recorded against the node',
      () async {
    final host = await net.node('Living Room TV', 'node-a');
    final laptop = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    await net.pair(host, laptop);
    final hostKeys = (await host.backup.pairKeys())!;

    // node-x presents the host's own public keys.
    expect(
        await host.backup
            .addMemberForPair(hostKeys.signer, hostKeys.box, nodeId: 'node-x'),
        isNotNull);
    expect(host.meta.nodeToSlot().containsKey('node-x'), isFalse);
  });

  test('a host add past its deadline writes nothing', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    final keys = (await joiner.backup.pairKeys())!;
    final before = net.backupRelay.requests.length;

    final vaultId = await host.backup.addMemberForPair(keys.signer, keys.box,
        nodeId: 'node-b',
        deadline: DateTime.now().subtract(const Duration(seconds: 1)));

    expect(vaultId, isNull);
    expect(net.backupRelay.requests.skip(before), isEmpty);
    expect(net.backupRelay.onlyVault.members, hasLength(2));
  });

  group('a relay that never answers', () {
    setUp(() => net.hookTimeout = const Duration(milliseconds: 200));

    test('does not hold up the host reply', () async {
      final host = await net.node('Living Room TV', 'node-a');
      final joiner = await net.node('Night Harbor Laptop', 'node-b');
      await host.enableBackup();
      net.backupRelay.hangWhen = (_) => true;

      final clock = Stopwatch()..start();
      final offer = await host.peers.startPairingOffer();
      await joiner.peers.pairWithCode(offer.code);

      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      expect(joiner.peers.isPaired, isTrue);
      expect(joiner.backup.enabled, isFalse);
    });

    test('does not hold up the joiner', () async {
      final host = await net.node('Living Room TV', 'node-a');
      final joiner = await net.node('Night Harbor Laptop', 'node-b');
      await host.enableBackup();
      final signer = (await joiner.backup.pairKeys())!.signer;
      net.backupRelay.hangWhen =
          (r) => (r.headers['authorization'] ?? '').contains('signer=$signer');

      final clock = Stopwatch()..start();
      final offer = await host.peers.startPairingOffer();
      await joiner.peers.pairWithCode(offer.code);

      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      expect(joiner.peers.isPaired, isTrue);
      expect(host.store.member('node-b')!.revoked, isFalse);
    });

    test('an add that lands after the host\'s deadline is taken out again',
        () async {
      final host = await net.node('Living Room TV', 'node-a');
      final joiner = await net.node('Night Harbor Laptop', 'node-b');
      await host.enableBackup();
      final keys = (await joiner.backup.pairKeys())!;
      final posted = Completer<void>();
      net.backupRelay.hangWhen = (r) {
        final add = r.method == 'POST' && r.url.path.endsWith('/members');
        if (add && !posted.isCompleted) posted.complete();
        return add;
      };

      final deadline = DateTime.now().add(const Duration(hours: 1));
      final result = host.backup.addMemberForPair(keys.signer, keys.box,
          nodeId: 'node-b', deadline: deadline);
      // The POST is in flight, so the deadline check before it has passed.
      await posted.future;
      // The host gives up while the relay still holds the write, which it
      // then applies.
      host.clockOverride = deadline.add(const Duration(seconds: 1));
      net.backupRelay.hangWhen = null;
      net.backupRelay.releaseHung();

      expect(await result, isNull);
      expect(joiner.backup.enabled, isFalse);

      final vault = net.backupRelay.onlyVault;
      expect(vault.members, hasLength(2),
          reason: 'no member the joiner does not know it is');
      expect(vault.epoch, 2);
      expect(host.meta.nodeToSlot().containsKey('node-b'), isFalse);
      expect((await host.state())!.keysByEpoch.keys, contains(2));
    });

    test('does not hold up a revocation', () async {
      final host = await net.node('Living Room TV', 'node-a');
      final joiner = await net.node('Night Harbor Laptop', 'node-b');
      await host.enableBackup();
      await net.pair(host, joiner);
      net.backupRelay.hangWhen = (_) => true;

      final clock = Stopwatch()..start();
      await host.peers.revokePeer('node-b');

      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      expect(host.store.member('node-b')!.revoked, isTrue);
    });
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

    // An offer from the old vault's members means nothing in the new one.
    await joiner.meta.putPending(const PendingAccountOffer(
      accountId: 'p1',
      kind: 'plex',
      displayName: 'Night Harbor Plex',
      fromDevice: 'Old Laptop',
      updatedAt: 1,
    ));
    await joiner.meta.dismiss('p2', 1);

    await joiner.backup.resolveVaultChoice(keepOffered: true);

    expect(joiner.meta.pendingAccounts(), isEmpty);
    expect(joiner.meta.isDismissed('p2', 1), isFalse);
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

  test('keeping the current vault leaves the offered one', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    await joiner.enableBackup();
    final hostVault = (await host.state())!.vaultId;
    final ownVault = (await joiner.state())!.vaultId;
    await net.pair(host, joiner);
    final joinerSlot = await joiner.slotId();
    expect(net.backupRelay.vault(hostVault).members.values.map((m) => m.slotId),
        contains(joinerSlot));

    await joiner.backup.resolveVaultChoice(keepOffered: false);

    expect(joiner.backup.pendingVaultChoice.value, isNull);
    expect((await joiner.state())!.vaultId, ownVault);
    expect(net.backupRelay.vaults, hasLength(2));
    final offered = net.backupRelay.vault(hostVault);
    expect(offered.members.values.map((m) => m.slotId),
        isNot(contains(joinerSlot)));
    expect(offered.epoch, 2, reason: 'leaving rotates the vault key');
  });

  test('adoptVault before start keeps a stored vault', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    await joiner.enableBackup();
    final hostVault = (await host.state())!.vaultId;
    final ownVault = (await joiner.state())!.vaultId;

    final fresh = BackupSyncService(
      relay: net.backupRelay.relayClient(),
      authStorage: joiner.auth,
      meta: joiner.meta,
      snapshot: joiner.snapshot,
      deviceName: () async => joiner.name,
      platform: 'linux',
    );
    addTearDown(fresh.dispose);
    await fresh.adoptVault(hostVault);

    expect((await joiner.state())!.vaultId, ownVault);
    expect(fresh.pendingVaultChoice.value,
        (current: ownVault, offered: hostVault));
  });

  test('declining the offered vault clears the choice even without identity',
      () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = await net.node('Night Harbor Laptop', 'node-b');
    await host.enableBackup();
    await joiner.enableBackup();
    final hostVault = (await host.state())!.vaultId;

    // A service that has not started holds no identity, and this one
    // cannot load it.
    final fresh = BackupSyncService(
      relay: net.backupRelay.relayClient(),
      authStorage: joiner.auth,
      meta: joiner.meta,
      snapshot: joiner.snapshot,
      deviceName: () async => joiner.name,
      platform: 'linux',
    );
    addTearDown(fresh.dispose);
    await fresh.adoptVault(hostVault);
    expect(fresh.pendingVaultChoice.value, isNotNull);
    await joiner.auth.write(BackupIdentity.storageKey, 'not json');

    await fresh.resolveVaultChoice(keepOffered: false);

    expect(fresh.pendingVaultChoice.value, isNull);
  });

  test('adoptVault aborts when the stored state cannot be read', () async {
    final host = await net.node('Living Room TV', 'node-a');
    final joiner = _Node('Night Harbor Laptop', 'node-b', net);
    net.nodes.add(joiner);
    await host.enableBackup();
    final hostVault = (await host.state())!.vaultId;
    await joiner.auth.write(BackupVaultStateStore.storageKey, '{"v": 9}');

    await expectLater(joiner.backup.adoptVault(hostVault), throwsA(anything));

    expect(
        await joiner.auth.read(BackupVaultStateStore.storageKey), '{"v": 9}');
    expect(joiner.backup.showJoinedNotice, isFalse);
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
