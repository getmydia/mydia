import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_controller.dart';
import 'package:player/core/backup/backup_identity.dart';
import 'package:player/core/backup/backup_meta_store.dart';
import 'package:player/core/backup/backup_relay_client.dart';
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

  /// The cloud backends of the current controller, by store kind.
  final backends = <BackupStoreKind, InMemoryCloudBackend>{};

  /// Replaces the controller's host-side store hook when set.
  CloudStoreForPairHook? cloudStoreForPair;
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
        backend: backends[kind] = InMemoryCloudBackend(net.stores[kind]!,
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
      cloudStoreForPair: cloudStoreForPair ?? hooks.cloudStoreForPair,
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

  test('switch_to_signed_out_cloud_leaves_relay_untouched', () async {
    final a = net.device('Living Room TV');
    await a.enableRelayDirectly();
    final vaultId = (await a.vault())!.vaultId;
    final c = a.restart();
    await c.start();
    await _settled(c);
    a.backends[BackupStoreKind.gdrive]!.signedIn = false;
    final slot = await a.slotId();
    final relayWrites = net.relay.slotWrites[slot];

    await expectLater(
        c.switchTo(BackupStoreKind.gdrive, deleteOld: true),
        throwsA(isA<BackupRelayException>()
            .having((e) => e.kind, 'kind', BackupRelayError.signedOut)));

    expect(c.active.value, BackupStoreKind.relay);
    expect(await a.auth.read(BackupController.storeKey), 'relay');
    expect(net.relay.vaults.keys, contains(vaultId),
        reason: 'the old backup is not deleted');
    expect(net.relay.slotWrites[slot], relayWrites, reason: 'no stub');
    expect((await a.vault())?.vaultId, vaultId);
    expect(a.relay.enabled, isTrue);
    expect(a.relay.dormant, isFalse);
    expect(net.stores[BackupStoreKind.gdrive]!.bytes, isEmpty);
    // Paused while Drive was tried, the relay syncs again.
    final requests = net.relay.requests.length;
    await c.poll();
    expect(net.relay.requests.length, greaterThan(requests));
  });

  test('switch_to_signed_out_cloud_leaves_the_other_cloud_untouched', () async {
    final a = net.device('Living Room TV');
    final b = net.device('Night Harbor Laptop');
    await a.controller.ready;
    await a.controller.enableCloud(BackupStoreKind.gdrive);
    await b.controller.ready;
    await b.controller.enableCloud(BackupStoreKind.gdrive);
    final drive = net.stores[BackupStoreKind.gdrive]!;
    final slot = await a.slotId();
    final driveWrites = drive.writes[slot];
    a.backends[BackupStoreKind.icloud]!.signedIn = false;

    await expectLater(
        a.controller.switchTo(BackupStoreKind.icloud, deleteOld: true),
        throwsA(isA<BackupRelayException>()));

    expect(a.controller.active.value, BackupStoreKind.gdrive);
    expect(await a.auth.read(BackupController.storeKey), 'gdrive');
    expect(drive.writes[slot], driveWrites, reason: 'no stub');
    expect(drive.bytes.keys, containsAll([slot, await b.slotId()]),
        reason: 'the old backup is not deleted');
    expect(a.controller.cloud(BackupStoreKind.gdrive).enabled, isTrue);
    expect(net.stores[BackupStoreKind.icloud]!.bytes, isEmpty);
  });

  test('switch_cloud_to_cloud_keeps_the_new_store_state', () async {
    final a = net.device('Living Room TV');
    final b = net.device('Night Harbor Laptop');
    await a.controller.ready;
    await a.controller.enableCloud(BackupStoreKind.gdrive);
    await b.controller.ready;
    await b.controller.enableCloud(BackupStoreKind.icloud);
    final bSlot = await b.slotId();

    await a.controller.switchTo(BackupStoreKind.icloud, deleteOld: false);

    expect(a.controller.active.value, BackupStoreKind.icloud);
    expect(a.controller.cloud(BackupStoreKind.gdrive).enabled, isFalse);
    // Leaving Drive after joining iCloud keeps what iCloud merged.
    expect(a.meta.slotNames()[bSlot], 'Night Harbor Laptop');
    expect(a.meta.mergedVersion(bSlot, store: 'icloud'), isNotNull);
    await b.controller.poll();
    await _settled(b.controller);
    expect(net.stores[BackupStoreKind.gdrive]!.bytes.keys,
        contains(await a.slotId()),
        reason: 'the moved stub stays in Drive');
  });

  test('old_store_failure_after_switch_keeps_new_store_active', () async {
    final a = net.device('Living Room TV');
    await a.enableRelayDirectly();
    final c = a.restart();
    await c.start();
    await _settled(c);
    net.relay.available = false;

    await expectLater(c.switchTo(BackupStoreKind.gdrive, deleteOld: false),
        throwsA(isA<BackupRelayException>()));

    expect(c.active.value, BackupStoreKind.gdrive);
    expect(await a.auth.read(BackupController.storeKey), 'gdrive');
    expect(c.cloud(BackupStoreKind.gdrive).enabled, isTrue);
  });

  test('failed_stub_write_detaches_old_relay_and_marks_dormant', () async {
    final a = net.device('Living Room TV');
    await a.enableRelayDirectly();
    final vaultId = (await a.vault())!.vaultId;
    final c = a.restart();
    await c.start();
    await _settled(c);
    net.relay.available = false;

    await expectLater(c.switchTo(BackupStoreKind.gdrive, deleteOld: false),
        throwsA(isA<BackupRelayException>()));
    net.relay.available = true;

    expect(c.active.value, BackupStoreKind.gdrive);
    // The old vault stops syncing and is dormant on disk, as a successful
    // leave leaves it (only the stub is missing).
    expect(a.relay.enabled, isFalse);
    expect(a.relay.dormant, isTrue);
    expect(a.relay.status.value, isA<BackupOff>());
    expect((await a.vault())?.vaultId, vaultId);
    // A host-side pairing no longer adds joiners to it.
    final joiner = await BackupIdentity.loadOrCreate(MockAuthStorage());
    expect(
        await a.relay.addMemberForPair(
            await joiner.signerPublicB64(), await joiner.boxPublicB64()),
        isNull);
    final before = net.relay.requests.length;
    await a.watch('tmdb:movie:7');
    a.relay.markDirty();
    await a.relay.flush();
    await a.relay.poll();
    expect(net.relay.requests.length, before, reason: 'no relay sync');

    // A restart does not wake it.
    final again = a.restart();
    await again.start();
    await _settled(again);
    expect(a.relay.enabled, isFalse);
    expect(net.relay.requests.length, before);

    // Switching back resumes the same vault, no new recovery key needed.
    await again.switchTo(BackupStoreKind.relay, deleteOld: false);
    expect(again.active.value, BackupStoreKind.relay);
    expect(a.relay.enabled, isTrue);
    expect(a.relay.dormant, isFalse);
    expect((await a.vault())!.vaultId, vaultId);
  });

  test('failed_stub_write_detaches_old_cloud_and_switch_back_works', () async {
    final a = net.device('Living Room TV');
    await a.controller.ready;
    await a.controller.enableCloud(BackupStoreKind.gdrive);
    await _settled(a.controller);
    final drive = a.controller.cloud(BackupStoreKind.gdrive);
    a.backends[BackupStoreKind.gdrive]!
        .failNext(const BackupRelayException(BackupRelayError.server));

    await expectLater(
        a.controller.switchTo(BackupStoreKind.icloud, deleteOld: false),
        throwsA(isA<BackupRelayException>()));

    expect(a.controller.active.value, BackupStoreKind.icloud);
    expect(drive.enabled, isFalse);
    expect(drive.status.value, isA<BackupOff>());
    final slot = await a.slotId();
    final writes = net.stores[BackupStoreKind.gdrive]!.writes[slot];
    await a.watch('tmdb:movie:8');
    drive.markDirty();
    await drive.poll();
    expect(net.stores[BackupStoreKind.gdrive]!.writes[slot], writes,
        reason: 'the old store does not sync');

    await a.controller.switchTo(BackupStoreKind.gdrive, deleteOld: false);
    expect(a.controller.active.value, BackupStoreKind.gdrive);
    expect(drive.enabled, isTrue);
    expect(a.controller.cloud(BackupStoreKind.icloud).enabled, isFalse);
  });

  test('reconnect_after_pause_resumes_sync', () async {
    final a = net.device('Living Room TV');
    await a.controller.ready;
    await a.controller.enableCloud(BackupStoreKind.gdrive);
    final drive = a.controller.cloud(BackupStoreKind.gdrive);
    await drive.settled();
    final slot = await a.slotId();
    final store = net.stores[BackupStoreKind.gdrive]!;

    await drive.pauseSync();
    final writes = store.writes[slot];
    await a.watch('tmdb:movie:9');
    drive.markDirty();
    await drive.flush();
    expect(store.writes[slot], writes, reason: 'paused');

    await drive.reconnect();
    await a.watch('tmdb:movie:10');
    drive.markDirty();
    await drive.flush();
    expect(store.writes[slot], greaterThan(writes ?? 0));
  });

  test('init_failure_with_relay_vault_still_forwards_triggers', () async {
    final a = net.device('Living Room TV');
    await a.enableRelayDirectly();
    a.auth.failReadKeys.add(BackupController.storeKey);
    final c = a.restart();
    await expectLater(c.ready, throwsA(anything));

    await c.start();
    await a.relay.settled();

    expect(c.active.value, BackupStoreKind.relay);
    expect(a.relay.enabled, isTrue);
    final slot = await a.slotId();
    final writes = net.relay.slotWrites[slot] ?? 0;
    await a.watch('tmdb:movie:3');
    c.markDirty();
    await c.flush();
    expect(net.relay.slotWrites[slot], writes + 1);
  });

  test('a cloud store that cannot be built leaves the others offered',
      () async {
    final a = net.device('Living Room TV');
    a.controller.dispose();
    final c = a.controller = BackupController(
      relay: a.relay,
      authStorage: a.auth,
      resolveOffered: () async => _allStores,
      buildCloud: (kind) async {
        if (kind == BackupStoreKind.icloud) throw StateError('no plugin');
        return buildCloudBackupService(
          backend:
              InMemoryCloudBackend(net.stores[kind]!, kind: kind.cloudKind!),
          authStorage: a.auth,
          meta: a.meta,
          snapshot: a.snapshot,
          deviceName: () async => a.name,
          platform: 'linux',
        );
      },
    );
    addTearDown(c.dispose);
    await c.ready;
    expect(c.offered.value, {BackupStoreKind.relay, BackupStoreKind.gdrive});
    await c.enableCloud(BackupStoreKind.gdrive);
    expect(c.active.value, BackupStoreKind.gdrive);
  });

  test('a host that leaves its group while naming its store rejects pairing',
      () async {
    final host = net.device('Living Room TV', 'node-a');
    final joiner = net.device('Night Harbor Laptop', 'node-b');
    host.cloudStoreForPair = () async {
      await host.peers().leaveGroup();
      return (store: 'gdrive', account: null);
    };
    await host.peers().start();
    await joiner.peers().start();

    final offer = await host.peers().startPairingOffer();
    await expectLater(
        joiner.peers().pairWithCode(offer.code), throwsA(anything));

    expect(joiner.peers().isPaired, isFalse);
    expect(host.peers().isPaired, isFalse);
    expect(joiner.controller.storeHint.value, isNull);
  });

  test('stores_do_not_share_merged_versions', () async {
    final meta = BackupMetaStore(InMemoryBackupMetaStorage());
    await meta.setMergedVersion('slot-x', '3', store: 'gdrive');
    expect(meta.mergedVersion('slot-x'), isNull, reason: 'not the relay');
    expect(meta.mergedVersion('slot-x', store: 'icloud'), isNull);
    await meta.setMergedVersion('slot-x', '5');
    await meta.setMergedVersion('slot-x', '7', store: 'icloud');
    expect(meta.mergedVersion('slot-x'), '5');
    expect(meta.mergedVersion('slot-x', store: 'gdrive'), '3');

    await meta.clearMergedSeqs(store: 'gdrive');
    expect(meta.mergedVersion('slot-x', store: 'gdrive'), isNull);
    expect(meta.mergedVersion('slot-x'), '5');
    expect(meta.mergedVersion('slot-x', store: 'icloud'), '7');
    await meta.clearMergedSeqs();
    expect(meta.mergedVersion('slot-x'), isNull);
    expect(meta.mergedVersion('slot-x', store: 'icloud'), '7');

    // Two devices on Drive: what one merges is recorded as Drive's only.
    final a = net.device('Living Room TV');
    final b = net.device('Night Harbor Laptop');
    await a.controller.ready;
    await a.controller.enableCloud(BackupStoreKind.gdrive);
    await b.controller.ready;
    await b.controller.enableCloud(BackupStoreKind.gdrive);
    await a.controller.poll();
    final bSlot = await b.slotId();
    expect(a.meta.mergedVersion(bSlot, store: 'gdrive'), isNotNull);
    expect(a.meta.mergedVersion(bSlot), isNull);
  });

  test('cloud_to_relay_new_vault_merges_slot_with_colliding_version', () async {
    final a = net.device('Living Room TV');
    final b = net.device('Night Harbor Laptop');
    final bSlot = await b.slotId();
    await a.controller.ready;
    await a.controller.enableCloud(BackupStoreKind.gdrive);

    final key = await a.relay.prepareEnable();
    await a.controller
        .switchTo(BackupStoreKind.relay, deleteOld: false, relayKey: key);
    final vaultId = (await a.vault())!.vaultId;
    // Drive merged B's slot at version "3" (a Drive poll that ran late, or a
    // record kept from it).
    await a.meta.setMergedVersion(bSlot, '3', store: 'gdrive');

    // B joins the new vault and uploads until its slot is at seq 3.
    await b.relay.start();
    await b.relay.commitRestore(await b.relay.previewRestore(key.display));
    for (var i = 0; net.relay.vault(vaultId).slots[bSlot]!.seq < 3; i++) {
      await b.watch('tmdb:movie:${100 + i}');
      b.relay.markDirty();
      await b.relay.flush();
    }
    expect(net.relay.vault(vaultId).slots[bSlot]!.seq, 3);
    await b.watch('tmdb:movie:0');
    expect(a.sync.watchRecord('tmdb:movie:101'), isNull);

    await a.controller.poll();

    expect(a.sync.watchRecord('tmdb:movie:101')?.watched, isTrue,
        reason: 'B slot at seq 3 is merged despite Drive version "3"');
    expect(a.meta.mergedVersion(bSlot), '3');
  });

  test('paused_store_does_not_sync_until_resumed', () async {
    final a = net.device('Living Room TV');
    await a.enableRelayDirectly();
    await a.relay.settled();

    await a.relay.pauseSync();
    final requests = net.relay.requests.length;
    await a.relay.poll();
    await a.watch('tmdb:movie:5');
    a.relay.markDirty();
    await a.relay.flush();
    expect(net.relay.requests.length, requests);

    a.relay.resumeSync();
    await a.relay.poll();
    expect(net.relay.requests.length, greaterThan(requests));
    expect(a.relay.enabled, isTrue);
  });
}
