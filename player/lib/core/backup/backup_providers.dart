/// Wires the cloud backup into the app: the stores [BackupSnapshot] reads
/// and writes, the active store ([BackupController]) and the triggers that
/// drive it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;

import '../auth/auth_storage.dart';
import '../auth/device_info_service.dart';
import '../cache/watcher_registry.dart' show invalidatorProvider;
import '../p2p/p2p_service.dart' show p2pServiceProvider;
import '../p2p/peer_sync_service.dart';
import '../p2p/peer_sync_store.dart';
import '../player/platform_features.dart';
import '../player/subtitle_language_prefs.dart';
import '../settings/settings_providers.dart';
import '../sources/files/files_media_source.dart';
import '../sources/files/files_providers.dart'
    show filesIndexProvider, filesStorageOpenProvider;
import '../sources/files/files_scan_controller.dart';
import '../sources/files/index/index_records.dart' show LibraryRoot;
import '../sources/source.dart' show Source;
import '../sources/sources_providers.dart';
import 'backup_controller.dart';
import 'backup_meta_store.dart';
import 'backup_relay_client.dart';
import 'backup_snapshot.dart';
import 'backup_sync_service.dart';
import 'cloud/cloudkit_backend.dart';
import 'cloud/google_auth.dart';
import 'cloud/google_drive_backend.dart';

export 'backup_controller.dart';
export 'backup_sync_service.dart';

final backupMetaStoreProvider = Provider<BackupMetaStore>(
  (ref) => BackupMetaStore(backupMetaStorageFromHive()),
);

/// Keys of the `peer_sync` box whose changes are backed up: watch state and
/// pins. Roster and watermark writes are not.
bool _backedUpPeerSyncKey(Object? key) {
  final k = key.toString();
  return k.startsWith('watch:') || k.startsWith('pin:');
}

final backupSnapshotProvider = Provider<BackupSnapshot>((ref) {
  final store = ref.watch(peerSyncStoreProvider);
  return BackupSnapshot(
    peerSync: store,
    authStorage: getAuthStorage(),
    meta: ref.watch(backupMetaStoreProvider),
    loadSources: () => ref.read(sourceRecordsProvider.future),
    putAccount: (record) =>
        ref.read(sourceRecordsProvider.notifier).putAccount(record),
    settings: ref.watch(coreSettingsServiceProvider),
    loadSubtitleLanguages: SubtitleLanguagePrefs.loadSaved,
    saveSubtitleLanguages: SubtitleLanguagePrefs.save,
    onRemoteFilesChanges: (watchKeys, pinKeys) => applyRemoteFilesChanges(
      store: store,
      sources: FilesMediaSource.activeSources.toList(),
      changedWatchKeys: watchKeys,
      changedPinKeys: pinKeys,
    ),
    rootsFor: (accountId) async => ref.read(filesStorageOpenProvider)
        ? ref.read(filesIndexProvider(accountId)).roots()
        : const <LibraryRoot>[],
    putRoots: (accountId, roots) => _putRoots(ref, accountId, roots),
  );
});

/// Adds restored folder roots to [accountId]'s index, then does what adding
/// a folder by hand does (`FilesAccounts._addRoot`): invalidates the landed
/// groups and starts a scan.
Future<void> _putRoots(
  Ref ref,
  String accountId,
  List<LibraryRoot> roots,
) async {
  if (!ref.read(filesStorageOpenProvider)) return;
  final index = ref.read(filesIndexProvider(accountId));
  for (final root in roots) {
    await index.putRoot(root);
  }
  final snapshot = await ref.read(sourceRecordsProvider.future);
  final record = snapshot.accounts
      .where((a) => a.account.id == accountId)
      .firstOrNull;
  for (final source in record?.sources ?? const <Source>[]) {
    await ref
        .read(invalidatorProvider)
        .invalidate(FilesMediaSource.groupLandedTargets(source.id));
    unawaited(
      ref.read(filesScanProvider(source.id).notifier).rescan().catchError((
        Object e,
      ) {
        debugPrint(
          '[Backup] Scan after restoring a folder failed: ${e.runtimeType}',
        );
      }),
    );
  }
}

/// The relay backup (#1414's service). Its triggers come from
/// [backupControllerProvider], which forwards them only while the relay is
/// the active store; screens for the relay read it here.
final Provider<BackupSyncService> backupSyncServiceProvider =
    Provider<BackupSyncService>((ref) {
      final device = DeviceInfoService();
      final service = BackupSyncService(
        relay: BackupRelayClient(),
        authStorage: getAuthStorage(),
        meta: ref.watch(backupMetaStoreProvider),
        snapshot: ref.watch(backupSnapshotProvider),
        deviceName: device.getDeviceName,
        platform: device.getPlatform(),
        localNodeId: () => ref.read(p2pServiceProvider).nodeId,
      );
      ref.onDispose(service.dispose);
      return service;
    });

/// The Google account Drive backs up to, null where Drive is not offered
/// (the web, or a build without this platform's client id).
final Provider<GoogleAuth?> googleAuthProvider = Provider<GoogleAuth?>(
  (ref) => kIsWeb ? null : googleAuthForPlatform(getAuthStorage()),
);

/// The one [CloudKitBackend] of the app: its change EventChannel has a
/// single native sink, so a second instance would steal the first's
/// events. iOS and macOS only.
final Provider<CloudKitBackend> cloudKitBackendProvider =
    Provider<CloudKitBackend>(
      (ref) => CloudKitBackend(meta: ref.watch(backupMetaStoreProvider)),
    );

/// The active backup store and its triggers. Native only: `app.dart`
/// starts it after peer sync and forwards `paused` (flush) and `resumed`
/// (poll).
final Provider<BackupController>
backupControllerProvider = Provider<BackupController>((ref) {
  final device = DeviceInfoService();
  final auth = getAuthStorage();
  final meta = ref.watch(backupMetaStoreProvider);
  final snapshot = ref.watch(backupSnapshotProvider);
  final google = ref.watch(googleAuthProvider);
  final apple = !kIsWeb && (PlatformFeatures.isIOS || PlatformFeatures.isMacOS);
  final cloudKit = apple ? ref.watch(cloudKitBackendProvider) : null;
  final driveClient = http.Client();

  final controller = BackupController(
    relay: ref.watch(backupSyncServiceProvider),
    authStorage: auth,
    googleAuth: google,
    initialOffered: kIsWeb
        ? const {}
        : {BackupStoreKind.relay, if (google != null) BackupStoreKind.gdrive},
    resolveOffered: () => resolveOfferedStores(
      web: kIsWeb,
      apple: apple,
      google: google != null,
      cloudKitEnabled: CloudKitBackend.isEnabled,
    ),
    buildCloud: (kind) => buildCloudBackupService(
      backend: switch (kind) {
        BackupStoreKind.icloud => cloudKit!,
        BackupStoreKind.gdrive => GoogleDriveBackend(
          auth: google!,
          client: driveClient,
          meta: meta,
        ),
        BackupStoreKind.relay => throw ArgumentError.value(
          kind,
          'kind',
          'is not a cloud store',
        ),
      },
      authStorage: auth,
      meta: meta,
      snapshot: snapshot,
      deviceName: device.getDeviceName,
      platform: device.getPlatform(),
    ),
  );

  // A watch or pin written by anyone (playback, the UI, a p2p merge).
  StreamSubscription<BoxEvent>? peerSyncSub;
  if (Hive.isBoxOpen(PeerSyncStore.boxName)) {
    peerSyncSub = Hive.box<Map<dynamic, dynamic>>(PeerSyncStore.boxName)
        .watch()
        .where((e) => _backedUpPeerSyncKey(e.key))
        .listen((_) => controller.markDirty());
  }

  // A source account added, changed or removed. The first load is not a
  // change.
  ref.listen(sourceRecordsProvider, (previous, next) {
    if (previous is AsyncData &&
        next is AsyncData &&
        !identical(previous?.value, next.value)) {
      controller.markDirty();
    }
  });

  // A backed-up setting or the subtitle search languages changed.
  final stopSettings = watchBackedUpSettings(controller.markDirty);

  // Another device may have uploaded around a p2p sync.
  final peerStateSub = ref
      .watch(peerSyncServiceProvider)
      .onStateChanged
      .listen((_) => unawaited(controller.poll()));

  ref.onDispose(() {
    peerSyncSub?.cancel();
    peerStateSub.cancel();
    unawaited(stopSettings());
    controller.dispose();
    driveClient.close();
  });
  return controller;
});

/// What `peerSyncServiceProvider` hands [PeerSyncService]: with the relay,
/// pairing joins the group's vault and revocation flags the device for
/// removal from it (see [BackupSyncService.pendingRemovals]); with a cloud
/// store, pairing only passes the store on as a hint. Each hook reads
/// [backupControllerProvider] only when called: that provider watches
/// `peerSyncServiceProvider`, so reading it here would be a cycle.
final Provider<BackupPairingHooks> backupPairingHooksProvider =
    Provider<BackupPairingHooks>((ref) {
      if (kIsWeb) return const BackupPairingHooks();
      return backupPairingHooksFor(() => ref.read(backupControllerProvider));
    });
