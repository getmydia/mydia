import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_identity.dart';
import 'package:player/core/backup/backup_meta_store.dart';
import 'package:player/core/backup/backup_records.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/core/backup/backup_snapshot.dart';
import 'package:player/core/backup/backup_status.dart';
import 'package:player/core/backup/cloud/cloud_backend.dart';
import 'package:player/core/backup/cloud/cloud_backup_service.dart';
import 'package:player/core/backup/slot_sync_engine.dart';
import 'package:player/core/p2p/peer_group_secret.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../../test_utils/mock_auth_storage.dart';
import 'in_memory_cloud_backend.dart';

const _t0 = 1786000000000;

/// One install: every store the backup reads and writes, in memory, and a
/// [CloudBackupService] per cloud store kind, each over its own engine.
class _Device {
  _Device(this.name, this.accounts) {
    snapshot = BackupSnapshot(
      peerSync: sync,
      authStorage: auth,
      meta: meta,
      loadSources: sources.load,
      putAccount: sources.putAccount,
      settings: settings,
      loadSubtitleLanguages: () async => null,
      saveSubtitleLanguages: (_) async {},
      onRemoteFilesChanges: (_, __) async {},
      rootsFor: (_) async => const [],
      putRoots: (_, __) async {},
    );
  }

  final String name;

  /// The cloud account of each store kind this device signs in to.
  final Map<CloudStoreKind, InMemoryCloudStore> accounts;
  final auth = MockAuthStorage();
  final sources = InMemorySourceStore();
  final sync = InMemoryPeerSyncStore();
  final meta = BackupMetaStore(InMemoryBackupMetaStorage());
  late final settings = SettingsService(storage: auth);
  late final BackupSnapshot snapshot;
  final backends = <CloudStoreKind, InMemoryCloudBackend>{};
  final services = <CloudStoreKind, CloudBackupService>{};
  final engines = <SlotSyncEngine>[];

  Future<CloudBackupService> service(
      [CloudStoreKind kind = CloudStoreKind.gdrive]) async {
    final existing = services[kind];
    if (existing != null) return existing;
    final engine = SlotSyncEngine(
      meta: meta,
      snapshot: snapshot,
      deviceName: () async => name,
      platform: 'linux',
      clock: () => DateTime.fromMillisecondsSinceEpoch(_t0),
      filterOwn: CloudBackupService.filterOwn,
    );
    engines.add(engine);
    final backend =
        backends[kind] = InMemoryCloudBackend(accounts[kind]!, kind: kind);
    return services[kind] = CloudBackupService(
      engine: engine,
      backend: backend,
      identity: await BackupIdentity.loadOrCreate(auth),
      meta: meta,
      deviceName: () async => name,
      platform: 'linux',
      clock: () => DateTime.fromMillisecondsSinceEpoch(_t0),
    );
  }

  Future<String> slotId() async =>
      (await BackupIdentity.loadOrCreate(auth)).slotId;

  Future<void> watch(String key) => sync.setWatched(key, true, nowMs: _t0);

  bool watched(String key) => sync.watchRecord(key)?.watched ?? false;

  Future<List<String>> accountIds() async =>
      [for (final r in (await sources.load()).accounts) r.account.id];

  void dispose() {
    for (final e in engines) {
      e.dispose();
    }
  }
}

SourceAccountRecord _plex([String id = 'p1', String name = 'Night Harbor']) =>
    SourceAccountRecord(
      account: ProviderAccount(
        id: id,
        kind: SourceKind.plex,
        displayName: '$name Plex',
        storageNamespace: 'source/$id',
        activeProfileId: kOwnerProfileId,
      ),
      profiles: [
        SourceProfile(
            id: kOwnerProfileId, accountId: id, name: 'Ana', isOwner: true),
      ],
      servers: [
        SourceServer(
            id: 'srv-$id',
            accountId: id,
            profileId: kOwnerProfileId,
            name: name),
      ],
      addedAtMs: 1000,
    );

Matcher _throwsRelay(BackupRelayError kind) =>
    throwsA(isA<BackupRelayException>().having((e) => e.kind, 'kind', kind));

void main() {
  late InMemoryCloudStore drive;
  late InMemoryCloudStore icloud;
  final devices = <_Device>[];

  _Device device(String name) {
    final d = _Device(
        name, {CloudStoreKind.gdrive: drive, CloudStoreKind.icloud: icloud});
    devices.add(d);
    return d;
  }

  Future<_Device> enabled(String name,
      [CloudStoreKind kind = CloudStoreKind.gdrive]) async {
    final d = device(name);
    await (await d.service(kind)).enable();
    return d;
  }

  setUp(() {
    drive = InMemoryCloudStore();
    icloud = InMemoryCloudStore();
  });
  tearDown(() {
    for (final d in devices) {
      d.dispose();
    }
    devices.clear();
  });

  test('enable uploads this device and merges the others', () async {
    final a = device('Living Room TV');
    await a.watch('tmdb:movie:1');
    final sa = await a.service();
    await sa.enable();
    expect(sa.enabled, isTrue);
    expect(sa.accountLabel.value, 'ana@example.com');
    expect(drive.bytes.keys, [await a.slotId()]);

    final b = device('Laptop');
    await b.watch('tmdb:movie:2');
    await (await b.service()).enable();
    expect(b.watched('tmdb:movie:1'), isTrue);
    await sa.poll();
    expect(a.watched('tmdb:movie:2'), isTrue);
  });

  test('enable while signed out or unreachable throws and stays off', () async {
    final a = device('Living Room TV');
    final s = await a.service();
    a.backends[CloudStoreKind.gdrive]!.signedIn = false;
    await expectLater(s.enable(), _throwsRelay(BackupRelayError.signedOut));
    expect(s.enabled, isFalse);
    a.backends[CloudStoreKind.gdrive]!
      ..signedIn = true
      ..reachable = false;
    await expectLater(
        s.enable(), _throwsRelay(BackupRelayError.cloudUnavailable));
    expect(s.enabled, isFalse);
    expect(drive.bytes, isEmpty);
  });

  test('the listing cursor is kept per store kind in the meta store', () async {
    final a = await enabled('Living Room TV');
    expect(a.meta.cloudCursor('gdrive'), isNotNull);
    expect(a.meta.cloudCursor('icloud'), isNull);
  });

  test('group_records_never_written_to_cloud', () async {
    final a = device('Living Room TV');
    await a.auth.write(
        PeerGroupSecret.storageKey,
        PeerGroupSecret.fromBytes(Uint8List.fromList(List.filled(32, 3)))
            .toBase64Url());
    await a.watch('tmdb:movie:1');
    expect(
        (await a.snapshot.collect(nowMs: _t0)).whereType<GroupBackupRecord>(),
        isNotEmpty,
        reason: 'the device has a group record to leave out');
    await (await a.service()).enable();
    final stored = BackupPayload.decode(drive.bytes[await a.slotId()]!);
    expect(stored.records.whereType<GroupBackupRecord>(), isEmpty);
    expect(stored.records.whereType<WatchBackupRecord>(), isNotEmpty);
    expect(CloudBackupService.filterOwn(await a.snapshot.collect(nowMs: _t0)),
        isNot(contains(isA<GroupBackupRecord>())));
  });

  test('restore_on_empty_store_throws_notFound', () async {
    final a = device('Living Room TV');
    final s = await a.service();
    await expectLater(
        s.previewRestore(), _throwsRelay(BackupRelayError.notFound));

    // Only a moved stub and this device's own slot: still nothing to restore.
    final b = await enabled('Laptop');
    await (await b.service()).switchAway('relay', deleteOld: false);
    await s.enable();
    await s.disable();
    a.backends[CloudStoreKind.gdrive]!.signedIn = true;
    expect(drive.bytes.keys, hasLength(2));
    await expectLater(
        s.previewRestore(), _throwsRelay(BackupRelayError.notFound));
  });

  test('restore_applies_accounts_and_settings_then_joins', () async {
    final a = device('Living Room TV');
    await a.sources.putAccount(_plex());
    await a.settings.setDefaultQuality('1080p');
    await a.watch('tmdb:movie:1');
    await (await a.service()).enable();

    final b = device('Laptop');
    final sb = await b.service();
    final preview = await sb.previewRestore();
    expect(preview.payloads.keys, [await a.slotId()]);
    expect(preview.unreadableSlots, isEmpty);
    expect(preview.records.whereType<AccountBackupRecord>(), isNotEmpty);
    expect(b.watched('tmdb:movie:1'), isFalse,
        reason: 'a preview changes nothing');

    await sb.commitRestore(preview);
    expect(await b.accountIds(), ['p1']);
    expect(await b.settings.getDefaultQuality(), '1080p');
    expect(b.watched('tmdb:movie:1'), isTrue);
    expect(sb.enabled, isTrue);
    expect(drive.bytes.keys, containsAll([await a.slotId(), await b.slotId()]));
    expect(b.meta.pendingAccounts(), isEmpty);
  });

  test('restore while enabled is refused', () async {
    final a = await enabled('Living Room TV');
    await enabled('Laptop');
    final s = await a.service();
    final preview = await s.previewRestore();
    await expectLater(
        s.commitRestore(preview), throwsA(isA<BackupAlreadyOnException>()));
  });

  test('restore skips an unreadable slot and reports it', () async {
    await enabled('Living Room TV');
    drive.bytes['broken'] = [1, 2, 3];
    drive.versions['broken'] = ++drive.counter;
    final b = device('Laptop');
    final preview = await (await b.service()).previewRestore();
    expect(preview.unreadableSlots, {'broken'});
    expect(preview.payloads, hasLength(1));
  });

  test('slot_deleted_during_preview_is_skipped', () async {
    final a = await enabled('Living Room TV');
    final c = await enabled('Phone');
    final cSlot = await c.slotId();
    final b = device('Laptop');
    final sb = await b.service();
    // C's slot is listed, then removed before B reads it.
    b.backends[CloudStoreKind.gdrive]!.beforeRead = (slotId) async {
      if (slotId == cSlot) drive.bytes.remove(cSlot);
    };
    final preview = await sb.previewRestore();
    expect(preview.payloads.keys, [await a.slotId()]);
    expect(preview.unreadableSlots, {cSlot});
  });

  test('live_join_offers_accounts_not_applies', () async {
    final a = device('Living Room TV');
    await a.sources.putAccount(_plex());
    final sa = await a.service();
    await sa.enable();

    final b = device('Laptop');
    final sb = await b.service();
    await sb.enable();
    expect(await b.accountIds(), isEmpty,
        reason: 'a live device is offered accounts, not given them');
    expect(sb.pendingOffers.value.map((o) => o.accountId), ['p1']);
    expect(sb.pendingOffers.value.single.fromDevice, 'Living Room TV');

    await sb.acceptPendingAccount('p1');
    expect(await b.accountIds(), ['p1']);
    expect(sb.pendingOffers.value, isEmpty);

    await a.sources.putAccount(_plex('p2', 'Other'));
    sa.markDirty();
    await sa.flush();
    await sb.poll();
    expect(sb.pendingOffers.value.map((o) => o.accountId), ['p2']);
    await sb.dismissPendingAccount('p2');
    expect(sb.pendingOffers.value, isEmpty);
    expect(await b.accountIds(), ['p1']);
  });

  test('remove_device_deletes_slot_and_it_reappears_on_its_next_upload',
      () async {
    final a = await enabled('Living Room TV');
    final b = await enabled('Laptop');
    final sa = await a.service();
    final bSlot = await b.slotId();
    await sa.poll();
    expect(sa.slots.value.map((s) => s.slotId), contains(bSlot));

    await sa.removeDevice(bSlot);
    expect(drive.bytes.keys, isNot(contains(bSlot)));
    expect(drive.deletes, [bSlot]);
    expect(sa.slots.value.map((s) => s.slotId), isNot(contains(bSlot)));
    await expectLater(sa.removeDevice(await a.slotId()), throwsArgumentError);

    // Removal is cleanup: B, still signed in, writes its slot again.
    await (await b.service()).poll();
    expect(drive.bytes.keys, contains(bSlot));
    await sa.poll();
    expect(sa.slots.value.map((s) => s.slotId), contains(bSlot));
  });

  test('switch_away_leaves_stub_and_other_device_sees_moved', () async {
    final a = await enabled('Living Room TV');
    await a.watch('tmdb:movie:1');
    final b = await enabled('Laptop');
    final sa = await a.service();
    await sa.switchAway('icloud', deleteOld: false);
    expect(sa.enabled, isFalse);
    expect(sa.status.value, isA<BackupOff>());

    final aSlot = await a.slotId();
    final stub = BackupPayload.decode(drive.bytes[aSlot]!);
    expect(stub.movedTo, 'icloud');
    expect(stub.records, isEmpty);
    expect(stub.deviceName, 'Living Room TV');
    expect(drive.deletes, isEmpty);
    expect(a.watched('tmdb:movie:1'), isTrue, reason: 'local data stays');

    final sb = await b.service();
    await sb.poll();
    expect(sb.movedSlots.value, {aSlot: 'icloud'});
  });

  test('switch away deleting the old backup keeps only the moved stub',
      () async {
    final a = await enabled('Living Room TV');
    final b = await enabled('Laptop');
    final sa = await a.service();
    await sa.switchAway('icloud', deleteOld: true);
    expect(sa.enabled, isFalse);

    final aSlot = await a.slotId();
    expect(drive.bytes.keys, [aSlot]);
    expect(drive.deletes, [await b.slotId()]);
    expect(BackupPayload.decode(drive.bytes[aSlot]!).movedTo, 'icloud');

    // B, still signed in, is told where A went.
    final sb = await b.service();
    await sb.poll();
    expect(sb.movedSlots.value, {aSlot: 'icloud'});
  });

  test('crossed_switch_shows_prompt_both_ways', () async {
    // A leaves iCloud for Google Drive while B leaves Google Drive for
    // iCloud: each store ends up with the other device's stub.
    final a = await enabled('Living Room TV', CloudStoreKind.icloud);
    final b = await enabled('Laptop', CloudStoreKind.gdrive);
    await (await a.service(CloudStoreKind.icloud))
        .switchAway('gdrive', deleteOld: false);
    await (await b.service(CloudStoreKind.gdrive))
        .switchAway('icloud', deleteOld: false);
    final aOnDrive = await a.service(CloudStoreKind.gdrive);
    final bOnICloud = await b.service(CloudStoreKind.icloud);
    await aOnDrive.enable();
    await bOnICloud.enable();
    await aOnDrive.poll();

    expect(aOnDrive.movedSlots.value, {await b.slotId(): 'icloud'});
    expect(bOnICloud.movedSlots.value, {await a.slotId(): 'gdrive'});
    expect(drive.deletes, isEmpty);
    expect(icloud.deletes, isEmpty);
    expect(drive.bytes.keys, hasLength(2));
    expect(icloud.bytes.keys, hasLength(2));
  });

  test('disable detaches, signs out and keeps local data and the slot',
      () async {
    final a = await enabled('Living Room TV');
    await a.watch('tmdb:movie:1');
    await a.sources.putAccount(_plex());
    final s = await a.service();
    await s.disable();
    expect(s.enabled, isFalse);
    expect(s.status.value, isA<BackupOff>());
    expect(a.backends[CloudStoreKind.gdrive]!.signOuts, 1);
    expect(a.watched('tmdb:movie:1'), isTrue);
    expect(await a.accountIds(), ['p1']);
    expect(drive.bytes.keys, [await a.slotId()]);
  });

  test('deleteBackup deletes every slot, then disables', () async {
    final a = await enabled('Living Room TV');
    await a.watch('tmdb:movie:1');
    await enabled('Laptop');
    final s = await a.service();
    await s.deleteBackup();
    expect(drive.bytes, isEmpty);
    expect(s.enabled, isFalse);
    expect(a.backends[CloudStoreKind.gdrive]!.signOuts, 1);
    expect(a.watched('tmdb:movie:1'), isTrue);
  });

  test('a store signed out mid-session halts with signedOut until reconnect',
      () async {
    final a = await enabled('Living Room TV');
    final s = await a.service();
    final backend = a.backends[CloudStoreKind.gdrive]!;
    backend.signedIn = false;
    await s.poll();
    expect(
        s.status.value,
        isA<BackupError>()
            .having((e) => e.kind, 'kind', BackupRelayError.signedOut));
    await expectLater(s.reconnect(), _throwsRelay(BackupRelayError.signedOut));
    backend.signedIn = true;
    await s.reconnect();
    expect(s.status.value, isA<BackupIdle>());
  });
}
