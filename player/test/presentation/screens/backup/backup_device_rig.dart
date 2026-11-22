import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_meta_store.dart';
import 'package:player/core/backup/backup_snapshot.dart';
import 'package:player/core/backup/backup_sync_service.dart';
import 'package:player/core/backup/recovery_key.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../../core/backup/fake_backup_relay.dart';
import '../../../test_utils/mock_auth_storage.dart';

/// One install with a real [BackupSyncService] over in-memory stores, on a
/// shared [FakeBackupRelay]. Widget tests drive the engine through it with
/// `tester.runAsync`.
class BackupTestDevice {
  BackupTestDevice(this.relay, this.name) {
    snapshot = BackupSnapshot(
      peerSync: sync,
      authStorage: auth,
      meta: meta,
      loadSources: sources.load,
      putAccount: (record) {
        putAccounts.add(record.account.id);
        return sources.putAccount(record);
      },
      settings: SettingsService(storage: auth),
      loadSubtitleLanguages: () async => null,
      saveSubtitleLanguages: (_) async {},
      onRemoteFilesChanges: (_, _) async {},
      rootsFor: (_) async => const [],
      putRoots: (_, _) async {},
    );
    service = BackupSyncService(
      relay: relay.relayClient(),
      authStorage: auth,
      meta: meta,
      snapshot: snapshot,
      deviceName: () async => name,
      platform: 'linux',
    );
  }

  final FakeBackupRelay relay;
  final String name;
  final auth = MockAuthStorage();
  final sources = InMemorySourceStore();
  final sync = InMemoryPeerSyncStore();
  final meta = BackupMetaStore(InMemoryBackupMetaStorage());
  late final BackupSnapshot snapshot;
  late final BackupSyncService service;

  /// Account ids written through the backup's `putAccount`.
  final putAccounts = <String>[];

  Future<RecoveryKey> enable() async {
    await service.start();
    final key = await service.prepareEnable();
    await service.confirmEnable(key);
    return key;
  }

  Future<void> join(RecoveryKey key) async {
    await service.start();
    await service.commitRestore(await service.previewRestore(key.display));
  }

  bool _disposed = false;

  /// Disposes the service once, however often it is called.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    service.dispose();
  }

  Future<void> upload() async {
    service.markDirty();
    await service.flush();
  }
}

/// Lets the real engine's work (started by a tap) run, a slice of real time
/// and a frame at a time, until [until] holds.
Future<void> settleEngine(
  WidgetTester tester, {
  required bool Function() until,
}) async {
  for (var i = 0; i < 200 && !until(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pump();
}

/// A Plex account named after a fictional server.
SourceAccountRecord testPlexAccount(String id, String name) =>
    SourceAccountRecord(
      account: ProviderAccount(
        id: id,
        kind: SourceKind.plex,
        displayName: name,
        storageNamespace: 'source/$id',
        activeProfileId: kOwnerProfileId,
      ),
      profiles: [
        SourceProfile(
          id: kOwnerProfileId,
          accountId: id,
          name: 'Ana',
          isOwner: true,
        ),
      ],
      servers: [
        SourceServer(
          id: 'srv-$id',
          accountId: id,
          profileId: kOwnerProfileId,
          name: name,
        ),
      ],
      addedAtMs: 1000,
    );
