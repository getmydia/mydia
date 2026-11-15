import 'dart:typed_data';

import 'backup_records.dart';
import 'backup_relay_client.dart';
import 'backup_snapshot.dart';
import 'backup_vault_ops.dart';
import 'backup_meta_store.dart';

/// What the cloud backup is doing, for the settings screen.
sealed class BackupStatus {
  const BackupStatus();
}

/// Backup is not enabled on this device.
final class BackupOff extends BackupStatus {
  const BackupOff();
}

/// The relay has no `/backup/v1` routes. Nothing is retried until the next
/// app start.
final class BackupUnavailable extends BackupStatus {
  const BackupUnavailable();
}

final class BackupIdle extends BackupStatus {
  const BackupIdle(this.lastSuccessMs);

  /// When this device's slot was last uploaded, null before the first.
  final int? lastSuccessMs;
}

final class BackupUploading extends BackupStatus {
  const BackupUploading();
}

final class BackupError extends BackupStatus {
  const BackupError(this.kind, this.lastSuccessMs);

  final BackupRelayError kind;
  final int? lastSuccessMs;
}

/// Another member removed this device from the vault (or deleted it).
/// Local data is kept; `backup/vault` is cleared.
final class BackupRemoved extends BackupStatus {
  const BackupRemoved();
}

/// One device in the vault, for the settings screen's member list. The
/// recovery member is not one.
class BackupMemberInfo {
  const BackupMemberInfo({
    required this.slotId,
    required this.isThisDevice,
    this.deviceName,
    this.lastUploadMs,
  });

  final String slotId;
  final bool isThisDevice;

  /// From the device's own slot, null until a slot of it was read.
  final String? deviceName;

  /// The slot's `updated_at` (unix ms), null before its first upload.
  final int? lastUploadMs;
}

/// A device revoked from the p2p group that is still in the vault, so it
/// can still read the backup until it is removed (with
/// [BackupSyncService.removeMember]).
class PendingRemoval {
  const PendingRemoval({
    required this.nodeId,
    required this.slotId,
    this.deviceName,
  });

  final String nodeId;
  final String slotId;

  /// Its name in the vault, else in the p2p group; null when neither is
  /// known.
  final String? deviceName;
}

/// A recovery key's vault, read but not yet joined: what a restore would
/// bring. [BackupSyncService.commitRestore] applies it.
class RestorePreview {
  RestorePreview({
    required this.vaultId,
    required this.recovery,
    required this.manifest,
    required this.vaultKey,
    required this.payloads,
    required this.slotSeqs,
    required this.unreadableSlots,
  }) : records = lwwMerge(payloads.values.map((p) => p.records));

  final String vaultId;
  final RecoveryMember recovery;
  final BackupManifest manifest;
  final Uint8List vaultKey;

  /// Decoded slots by slot id.
  final Map<String, BackupPayload> payloads;
  final Map<String, int> slotSeqs;

  /// Slots that could not be read (corrupt, or at an epoch the recovery
  /// key has no key for).
  final Set<String> unreadableSlots;

  /// Every slot's records, merged.
  final List<BackupRecord> records;

  int get epoch => manifest.epoch;

  List<String> get deviceNames =>
      [for (final p in payloads.values) p.deviceName];

  int get sources =>
      records.whereType<AccountBackupRecord>().where((r) => !r.deleted).length;

  int get watchRecords =>
      records.whereType<WatchBackupRecord>().where((r) => !r.deleted).length;
}

/// Applies [payloads] merged: each winning record is applied with the name
/// of the device it came from, so an offer names its device. Settings and
/// the other restore-only records are therefore applied once, the newest.
Future<ApplyResult> applyByOrigin(
  BackupSnapshot snapshot,
  Map<String, BackupPayload> payloads, {
  required BackupApplyMode mode,
  required int nowMs,
}) async {
  final merged = lwwMerge(payloads.values.map((p) => p.records));
  // lwwMerge keeps the winning instances, so identity finds their origin.
  final winners = {for (final r in merged) r.key: r};
  var watch = 0, pins = 0, accounts = 0, settings = 0;
  final offers = <PendingAccountOffer>[];
  for (final p in payloads.values) {
    final mine = <BackupRecord>[];
    for (final r in p.records) {
      if (identical(winners[r.key], r)) {
        mine.add(r);
        winners.remove(r.key);
      }
    }
    if (mine.isEmpty) continue;
    final result = await snapshot.apply(mine,
        mode: mode, fromDevice: p.deviceName, nowMs: nowMs);
    watch += result.watchChanged;
    pins += result.pinsChanged;
    accounts += result.accountsAdded;
    settings += result.settingsApplied;
    offers.addAll(result.newOffers);
  }
  return ApplyResult(
    watchChanged: watch,
    pinsChanged: pins,
    accountsAdded: accounts,
    settingsApplied: settings,
    newOffers: offers,
  );
}
