import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_controller.dart';
import 'package:player/core/backup/backup_identity.dart';
import 'package:player/core/backup/backup_meta_store.dart';
import 'package:player/core/backup/backup_snapshot.dart';
import 'package:player/core/backup/backup_sync_service.dart';
import 'package:player/core/backup/backup_vault_state.dart';
import 'package:player/core/backup/recovery_key.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../test_utils/mock_auth_storage.dart';
import '../p2p/peer_sync_service_test.dart'
    show FakePeerSyncNetwork, FakePeerSyncTransport, FakeRelayClient, TestClock;
import 'cloud/in_memory_cloud_backend.dart';
import 'fake_backup_relay.dart';

const _t0 = 1786000000000;
const _allStores = {
  BackupStoreKind.relay,
  BackupStoreKind.icloud,
  BackupStoreKind.gdrive,
};

/// Completes once every operation queued so far, in every store of [c],
/// has run.
Future<void> _settled(BackupController c) async {
  await c.ready;
  await c.relay.settled();
  for (final kind in c.offered.value) {
    if (kind != BackupStoreKind.relay) await c.cloud(kind).settled();
  }
}

/// The shared services: the relay, one Drive and one iCloud account, and
/// the p2p network.
class _Net {
  final relay = FakeBackupRelay();
  final stores = {
    BackupStoreKind.gdrive: InMemoryCloudStore(),
    BackupStoreKind.icloud: InMemoryCloudStore(),
  };
  final network = FakePeerSyncNetwork();
  final claimRelay = FakeRelayClient();
  final clock = TestClock();
  final devices = <_Device>[];

  _Device device(String name, [String? nodeId]) {
    final d = _Device(name, nodeId ?? 'node-${devices.length}', this);
    devices.add(d);
    return d;
  }

  void dispose() {
    for (final d in devices) {
      d.dispose();
    }
  }
}

/// One install. [restart] builds a fresh relay service and controller over
/// the same stores, as after an app restart.
class _Device {
  _Device(this.name, this.nodeId, this.net) {
    snapshot = BackupSnapshot(
      peerSync: sync,
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
    restart();
  }

  final String name;
  final String nodeId;
  final _Net net;
  final auth = MockAuthStorage();
  final sources = InMemorySourceStore();
  final sync = InMemoryPeerSyncStore();
  final meta = BackupMetaStore(InMemoryBackupMetaStorage());
  late final BackupSnapshot snapshot;
  late BackupSyncService relay;
  late BackupController controller;
  Set<BackupStoreKind> offered = _allStores;
  final _old = <BackupController>[];
  PeerSyncService? _peers;
  FakePeerSyncTransport? _transport;

  BackupController restart() {
    relay = BackupSyncService(
      relay: net.relay.relayClient(),
      authStorage: auth,
      meta: meta,
      snapshot: snapshot,
      deviceName: () async => name,
      platform: 'linux',
      clock: () => DateTime.fromMillisecondsSinceEpoch(_t0),
    );
    final c = controller = BackupController(
      relay: relay,
      authStorage: auth,
      resolveOffered: () async => offered,
      buildCloud: (kind) => buildCloudBackupService(
        backend: InMemoryCloudBackend(net.stores[kind]!,
            kind: kind.cloudKind!, accountLabel: '$name@example.com'),
        authStorage: auth,
        meta: meta,
        snapshot: snapshot,
        deviceName: () async => name,
        platform: 'linux',
      ),
    );
    _old.add(c);
    return c;
  }

  Future<void> watch(String key) => sync.setWatched(key, true, nowMs: _t0);

  Future<String> slotId() async =>
      (await BackupIdentity.loadOrCreate(auth)).slotId;

  Future<BackupVaultState?> vault() => BackupVaultStateStore(auth).load();

  /// Relay backup on, set up the way #1414 did it: no controller involved.
  Future<RecoveryKey> enableRelayDirectly() async {
    await relay.start();
    final key = await relay.prepareEnable();
    await relay.confirmEnable(key);
    return key;
  }

  /// Pairing wired the way `backupPairingHooksProvider` wires it.
  PeerSyncService peers() {
    final existing = _peers;
    if (existing != null) return existing;
    final hooks = backupPairingHooksFor(() => controller);
    return _peers = PeerSyncService(
      store: sync,
      authStorage: auth,
      transport: _transport ??=
          FakePeerSyncTransport(network: net.network, localNodeId: nodeId),
      relayClient: net.claimRelay,
      deviceName: name,
      platform: 'linux',
      resolveDeviceName: () async => name,
      clock: net.clock.call,
      backupKeysForPair: hooks.backupKeysForPair,
      onJoinerBackupKeys: hooks.onJoinerBackupKeys,
      onJoinedVault: hooks.onJoinedVault,
      onPeerRevoked: hooks.onPeerRevoked,
      cloudStoreForPair: hooks.cloudStoreForPair,
      onCloudStoreHint: hooks.onCloudStoreHint,
    );
  }

  void dispose() {
    _peers?.dispose();
    _transport?.dispose();
    for (final c in _old) {
      c.dispose();
    }
  }
}

void main() {
  late _Net net;
  setUp(() => net = _Net());
  tearDown(() => net.dispose());

  test('install_with_relay_vault_and_no_store_key_is_relay', () async {
    final a = net.device('Living Room TV');
    // A #1414 install: no controller ever ran, so no key was written.
    a.controller.dispose();
    await a.enableRelayDirectly();
    expect(await a.auth.read(BackupController.storeKey), isNull);

    final c = a.restart();
    await c.ready;

    expect(c.active.value, BackupStoreKind.relay);
    expect(await a.auth.read(BackupController.storeKey), 'relay');
    await c.start();
    expect(a.relay.enabled, isTrue);

    final fresh = net.device('Night Harbor Laptop').controller;
    await fresh.ready;
    expect(fresh.active.value, isNull);
  });

  test('switch_relay_to_gdrive_writes_stub_and_key', () async {
    final a = net.device('Living Room TV');
    final key = await a.enableRelayDirectly();
    final b = net.device('Night Harbor Laptop');
    await b.relay.start();
    await b.relay.commitRestore(await b.relay.previewRestore(key.display));
    final vaultId = (await a.vault())!.vaultId;

    final c = a.restart();
    await c.start();
    await c.switchTo(BackupStoreKind.gdrive, deleteOld: false);

    expect(c.active.value, BackupStoreKind.gdrive);
    expect(await a.auth.read(BackupController.storeKey), 'gdrive');
    expect(c.cloud(BackupStoreKind.gdrive).enabled, isTrue);
    expect(net.stores[BackupStoreKind.gdrive]!.bytes.keys,
        contains(await a.slotId()));
    // The relay vault stays on disk, dormant, and A stays a member so the
    // stub stays readable.
    expect(a.relay.enabled, isFalse);
    expect(a.relay.dormant, isTrue);
    expect((await a.vault())?.vaultId, vaultId);
    expect(
        net.relay
            .vault(vaultId)
            .members
            .values
            .map((m) => m.slotId)
            .contains(await a.slotId()),
        isTrue);

    await b.relay.poll();
    expect(b.relay.movedSlots.value, {await a.slotId(): 'gdrive'});

    // A restart does not wake the dormant relay vault.
    final before = net.relay.requests.length;
    final again = a.restart();
    await again.start();
    await _settled(again);
    expect(again.active.value, BackupStoreKind.gdrive);
    expect(a.relay.enabled, isFalse);
    expect(a.relay.status.value, isA<BackupOff>());
    expect(net.relay.requests.length, before,
        reason: 'the dormant vault is not synced');
    expect(again.cloud(BackupStoreKind.gdrive).enabled, isTrue);

    // Nor does starting the relay service itself, as a relay screen might.
    await a.relay.start();
    await a.relay.settled();
    expect(a.relay.enabled, isFalse);
    expect(a.relay.status.value, isA<BackupOff>());
    expect(net.relay.requests.length, before);
    expect(again.active.value, BackupStoreKind.gdrive);
  });

  test('switch_relay_to_gdrive_deleting_the_old_backup', () async {
    final a = net.device('Living Room TV');
    await a.enableRelayDirectly();
    final c = a.restart();
    await c.start();

    await c.switchTo(BackupStoreKind.gdrive, deleteOld: true);

    expect(c.active.value, BackupStoreKind.gdrive);
    expect(net.relay.vaults, isEmpty);
    expect(await a.vault(), isNull);
    expect(a.relay.dormant, isFalse);
  });

  test('switch_gdrive_back_to_the_dormant_relay_vault', () async {
    final a = net.device('Living Room TV');
    await a.enableRelayDirectly();
    final vaultId = (await a.vault())!.vaultId;
    final c = a.restart();
    await c.start();
    await c.switchTo(BackupStoreKind.gdrive, deleteOld: false);

    await c.switchTo(BackupStoreKind.relay, deleteOld: false);

    expect(c.active.value, BackupStoreKind.relay);
    expect(await a.auth.read(BackupController.storeKey), 'relay');
    expect(a.relay.enabled, isTrue);
    expect(a.relay.dormant, isFalse);
    expect((await a.vault())!.vaultId, vaultId);
    expect(c.cloud(BackupStoreKind.gdrive).enabled, isFalse);
  });

  test('triggers_reach_only_active_service', () async {
    final a = net.device('Living Room TV');
    await a.enableRelayDirectly();
    final c = a.restart();
    await c.start();
    await _settled(c);
    final relaySlot = await a.slotId();
    final drive = net.stores[BackupStoreKind.gdrive]!;

    final relayWrites = net.relay.slotWrites[relaySlot] ?? 0;
    await a.watch('tmdb:movie:1');
    c.markDirty();
    await c.flush();
    expect(net.relay.slotWrites[relaySlot], relayWrites + 1);
    expect(drive.writes, isEmpty);

    await c.switchTo(BackupStoreKind.gdrive, deleteOld: true);
    final driveWrites = drive.writes[relaySlot]!;
    final relayRequests = net.relay.requests.length;

    await a.watch('tmdb:movie:2');
    c.markDirty();
    await c.flush();
    await c.poll();

    expect(drive.writes[relaySlot], driveWrites + 1);
    expect(net.relay.requests.length, relayRequests);
  });

  test('a cloud store keeps its last upload time across a restart', () async {
    final a = net.device('Living Room TV');
    final c = a.controller;
    await c.ready;
    await c.enableCloud(BackupStoreKind.gdrive);
    final status = c.cloud(BackupStoreKind.gdrive).status.value;
    expect(status, isA<BackupIdle>());
    final at = (status as BackupIdle).lastSuccessMs;
    expect(at, isNotNull);

    final again = a.restart();
    await again.ready;
    expect(again.active.value, BackupStoreKind.gdrive);
    await again.start();
    await _settled(again);
    final after = again.cloud(BackupStoreKind.gdrive).status.value;
    expect(after, isA<BackupIdle>());
    expect((after as BackupIdle).lastSuccessMs, at);
  });

  test('enabling the relay through its own screen makes it active', () async {
    final a = net.device('Living Room TV');
    final c = a.controller;
    await c.start();
    expect(c.active.value, isNull);

    await a.enableRelayDirectly();

    expect(c.active.value, BackupStoreKind.relay);
    await a.relay.disable();
    expect(c.active.value, isNull);
    expect(await a.auth.read(BackupController.storeKey), 'off');
  });

  test('offered_excludes_icloud_off_apple', () async {
    Future<Set<BackupStoreKind>> offered(
            {bool web = false,
            required bool apple,
            bool google = true,
            bool cloudKit = true}) =>
        resolveOfferedStores(
          web: web,
          apple: apple,
          google: google,
          cloudKitEnabled: () async => cloudKit,
        );

    expect(await offered(apple: false),
        {BackupStoreKind.relay, BackupStoreKind.gdrive});
    expect(await offered(apple: true), _allStores);
    expect(await offered(apple: true, cloudKit: false),
        {BackupStoreKind.relay, BackupStoreKind.gdrive});
    expect(await offered(apple: false, google: false), {BackupStoreKind.relay});
    expect(await offered(web: true, apple: true), isEmpty);

    final a = net.device('Living Room TV')
      ..offered = {BackupStoreKind.relay, BackupStoreKind.gdrive};
    final c = a.restart();
    await c.ready;
    expect(c.offered.value, {BackupStoreKind.relay, BackupStoreKind.gdrive});
    expect(() => c.cloud(BackupStoreKind.icloud), throwsStateError);
  });

  test('paired_hint_sets_storeHint_without_joining', () async {
    final host = net.device('Living Room TV', 'node-a');
    final joiner = net.device('Night Harbor Laptop', 'node-b');
    await host.controller.ready;
    await host.controller.enableCloud(BackupStoreKind.gdrive);
    await joiner.controller.start();
    await host.peers().start();
    await joiner.peers().start();

    final offer = await host.peers().startPairingOffer();
    await joiner.peers().pairWithCode(offer.code);
    await joiner.relay.settled();

    expect(joiner.peers().isPaired, isTrue);
    expect(
        joiner.controller.storeHint.value,
        const CloudStoreHint(
            BackupStoreKind.gdrive, 'Living Room TV@example.com'));
    expect(joiner.controller.active.value, isNull);
    expect(joiner.relay.enabled, isFalse);
    expect(joiner.controller.cloud(BackupStoreKind.gdrive).enabled, isFalse);
    expect(net.relay.vaults, isEmpty);
    expect(net.stores[BackupStoreKind.gdrive]!.bytes.keys,
        isNot(contains(await joiner.slotId())));

    // Kept across a restart until acknowledged.
    final again = joiner.restart();
    await again.ready;
    expect(again.storeHint.value?.kind, BackupStoreKind.gdrive);
    again.acknowledgeHint();
    expect(again.storeHint.value, isNull);
    await _settled(again);
    final third = joiner.restart();
    await third.ready;
    expect(third.storeHint.value, isNull);
  });

  test('a relay host still adds the joiner to its vault', () async {
    final host = net.device('Living Room TV', 'node-a');
    final joiner = net.device('Night Harbor Laptop', 'node-b');
    await host.enableRelayDirectly();
    await host.controller.start();
    await joiner.controller.start();
    await host.peers().start();
    await joiner.peers().start();

    final offer = await host.peers().startPairingOffer();
    await joiner.peers().pairWithCode(offer.code);
    await joiner.relay.settled();

    expect(joiner.relay.enabled, isTrue);
    expect((await joiner.vault())!.vaultId, (await host.vault())!.vaultId);
    expect(joiner.controller.active.value, BackupStoreKind.relay);
    expect(joiner.controller.storeHint.value, isNull);
  });

  test('a joiner on a cloud store is not added to a relay host vault',
      () async {
    final host = net.device('Living Room TV', 'node-a');
    final joiner = net.device('Night Harbor Laptop', 'node-b');
    await host.enableRelayDirectly();
    await host.controller.start();
    await joiner.controller.ready;
    await joiner.controller.enableCloud(BackupStoreKind.gdrive);
    await host.peers().start();
    await joiner.peers().start();

    final offer = await host.peers().startPairingOffer();
    await joiner.peers().pairWithCode(offer.code);
    await joiner.relay.settled();

    expect(joiner.peers().isPaired, isTrue);
    expect(joiner.relay.enabled, isFalse);
    expect(await joiner.vault(), isNull);
    expect(
        net.relay
            .vault((await host.vault())!.vaultId)
            .members
            .values
            .map((m) => m.slotId),
        isNot(contains(await joiner.slotId())));
    expect(joiner.controller.active.value, BackupStoreKind.gdrive);
  });
}
