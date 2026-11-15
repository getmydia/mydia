import 'dart:async';

import 'package:flutter/foundation.dart';

import '../backup_identity.dart';
import '../backup_meta_store.dart';
import '../backup_records.dart';
import '../backup_relay_client.dart';
import '../backup_snapshot.dart';
import '../backup_status.dart';
import '../slot_sync_engine.dart';
import '../slot_transport.dart';
import 'cloud_backend.dart';
import 'cloud_slot_transport.dart';

/// What a cloud store holds for a restore, read without changing anything.
/// The relay's `RestorePreview` carries a vault key and manifest, so it is
/// not reused.
class CloudRestorePreview {
  CloudRestorePreview({
    required this.payloads,
    required this.unreadableSlots,
  }) : records = lwwMerge(payloads.values.map((p) => p.records));

  /// Every other device's slot that read, by slot id. Moved stubs are left
  /// out.
  final Map<String, BackupPayload> payloads;

  /// Slots that could not be read (corrupt, or from a newer app version).
  final Set<String> unreadableSlots;

  /// Every slot's records, merged.
  final List<BackupRecord> records;

  List<String> get deviceNames =>
      [for (final p in payloads.values) p.deviceName];
}

/// The backup in one cloud store (iCloud or Google Drive): this device's
/// plaintext slot beside every other signed-in device's, merged by the same
/// rules as the relay. Membership is the account, so there is no vault,
/// recovery key or rotation: removing a device deletes its slot, and that
/// device writes it again on its next upload while still signed in.
///
/// Uploading, polling, merging, backoff and offers run in [SlotSyncEngine]
/// over a [CloudSlotTransport]. Every operation here runs in the engine's
/// queue ([SlotSyncEngine.serialise]); background triggers go through the
/// engine's own [markDirty], [poll] and [flush]. No operation clears local
/// data (watch state, sources, settings).
///
/// The engine must be built with [filterOwn], so the group record is not
/// uploaded (the transport drops it too).
class CloudBackupService {
  CloudBackupService({
    required SlotSyncEngine engine,
    required CloudBackend backend,
    required BackupIdentity identity,
    required BackupMetaStore meta,
    required Future<String> Function() deviceName,
    required String platform,
    DateTime Function()? clock,
  })  : _engine = engine,
        _backend = backend,
        _meta = meta,
        _deviceName = deviceName,
        _platform = platform,
        _clock = clock ?? DateTime.now,
        _transport = CloudSlotTransport(backend, identity.slotId);

  /// The engine's `filterOwn` for a cloud store.
  static const filterOwn = withoutGroupRecords;

  final SlotSyncEngine _engine;
  final CloudBackend _backend;
  final BackupMetaStore _meta;
  final Future<String> Function() _deviceName;
  final String _platform;
  final DateTime Function() _clock;
  final CloudSlotTransport _transport;
  final _accountLabel = ValueNotifier<String?>(null);

  CloudStoreKind get kind => _backend.kind;

  /// Whether this device syncs with the store.
  bool get enabled => _engine.attached;

  /// The signed-in account, as last checked, for "Backing up to Google
  /// Drive (a...@gmail.com)". Null while off.
  ValueListenable<String?> get accountLabel => _accountLabel;

  ValueListenable<BackupStatus> get status => _engine.status;
  ValueListenable<Set<String>> get unreadableSlots => _engine.unreadableSlots;
  ValueListenable<Map<String, String>> get movedSlots => _engine.movedSlots;
  ValueListenable<bool> get newerVersionSeen => _engine.newerVersionSeen;
  ValueListenable<List<PendingAccountOffer>> get pendingOffers =>
      _engine.pendingOffers;

  /// Every slot in the store, this device's first, as of the last poll.
  ValueListenable<List<SlotInfo>> get slots => _engine.slots;

  Map<String, String> get slotDeviceNames => _meta.slotNames();

  // Lifecycle

  /// Syncs with the store from now on, as on app start when this store is
  /// the active one: checks the account, then polls. A signed-out or
  /// unreachable account becomes the status and halts until [reconnect].
  Future<void> start() async {
    await _engine.serialise(() async {
      if (!enabled) _attach();
    });
    _engine.markDirty();
    unawaited(_engine.background(() async {
      _accountLabel.value = await _availableLabel();
      await _engine.pollOnce();
    }));
  }

  void dispose() {
    _engine.dispose();
    _accountLabel.dispose();
  }

  // Triggers

  void markDirty() => _engine.markDirty();
  Future<void> flush() => _engine.flush();
  Future<void> poll() => _engine.poll();

  // Enable and restore

  /// Checks the account, then uploads this device's slot and merges every
  /// other one. Throws `BackupRelayException` (`signedOut` or
  /// `cloudUnavailable`), touching nothing, when the account is not usable.
  Future<void> enable() => _userOp(() async {
        if (enabled) throw StateError('backup is already on');
        final label = await _availableLabel();
        await _forgetStore();
        await _join(label);
      });

  /// Reads every other device's slot. Changes nothing. Throws
  /// `BackupRelayException(notFound)` when the store holds no slot to
  /// restore (only this device's own, or moved stubs).
  Future<CloudRestorePreview> previewRestore() => _engine.serialise(() async {
        await _availableLabel();
        final listing = await _transport.list();
        final payloads = <String, BackupPayload>{};
        final unreadable = <String>{};
        for (final s in listing?.slots ?? const <SlotInfo>[]) {
          if (s.slotId == _transport.ownSlotId) continue;
          try {
            final p = await _transport.read(s);
            if (p.movedTo == null) payloads[s.slotId] = p;
          } on FormatException {
            debugPrint('[Backup] Slot ${s.slotId} is unreadable');
            unreadable.add(s.slotId);
          } on BackupRelayException catch (e) {
            // Deleted between the listing and the read.
            if (e.kind != BackupRelayError.notFound) rethrow;
            unreadable.add(s.slotId);
          }
        }
        if (payloads.isEmpty && unreadable.isEmpty) {
          throw const BackupRelayException(BackupRelayError.notFound);
        }
        return CloudRestorePreview(
            payloads: payloads, unreadableSlots: unreadable);
      });

  /// Applies [preview] in restore mode (accounts and settings are written),
  /// then joins the store as [enable] does. Throws
  /// [BackupAlreadyOnException], touching nothing, when already on.
  Future<ApplyResult> commitRestore(CloudRestorePreview preview) =>
      _userOp(() async {
        if (enabled) throw const BackupAlreadyOnException();
        final label = await _availableLabel();
        await _forgetStore();
        final result =
            await _engine.apply(preview.payloads, BackupApplyMode.restore);
        for (final e in preview.payloads.entries) {
          await _engine.rememberName(e.key, e.value.deviceName);
        }
        _engine.refreshOffers();
        await _join(label);
        return result;
      });

  /// After the viewer fixed a signed-out or unreachable account: checks it
  /// again, lifts the halt and polls. Throws as [enable] does while the
  /// account is still not usable.
  Future<void> reconnect() => _engine.serialise(() async {
        final label = await _availableLabel();
        _accountLabel.value = label;
        if (!enabled) return;
        _engine.resume();
        await _engine.attempt(_engine.pollOnce);
      });

  // Pending accounts

  Future<void> acceptPendingAccount(String accountId) =>
      _userOp(() => _engine.acceptOffer(accountId));

  Future<void> dismissPendingAccount(String accountId) =>
      _engine.serialise(() => _engine.dismissOffer(accountId));

  // Devices

  /// Deletes [slotId]'s slot. Cleanup, not revocation: that device can still
  /// read the store, and writes its slot again on its next upload while
  /// signed in. This device's own slot cannot be removed here.
  Future<void> removeDevice(String slotId) => _userOp(() async {
        if (slotId == _transport.ownSlotId) {
          throw ArgumentError.value(slotId, 'slotId', 'is this device');
        }
        await _transport.delete(slotId);
        if (enabled) await _engine.attempt(_engine.pollOnce);
      });

  // Leaving

  /// Moves this device's backup to the store [to]: rewrites its slot as a
  /// stub naming [to], so the other devices offer to follow, then deletes
  /// every other slot when [deleteOld], and stops syncing here. The stub
  /// stays either way: without it a device still signed in would never see
  /// the move, and would write its own slot again. The caller enables the
  /// new store.
  Future<void> switchAway(String to, {required bool deleteOld}) =>
      _userOp(() async {
        if (!enabled) throw StateError('backup is off');
        await _transport.writeOwn(BackupPayload(
          deviceName: await _deviceName(),
          platform: _platform,
          createdAt: _clock().millisecondsSinceEpoch,
          records: const [],
          movedTo: to,
        ));
        if (deleteOld) await _deleteAll(keepOwn: true);
        await _leave();
      });

  /// Stops syncing and forgets the account's credentials on this device.
  /// The slots stay in the store.
  Future<void> disable() => _userOp(() async {
        await _leave();
        await _backend.signOut();
      });

  /// Deletes every slot in the store, for every device, then [disable]s.
  Future<void> deleteBackup() => _userOp(() async {
        await _deleteAll();
        await _leave();
        await _backend.signOut();
      });

  // Internals

  /// The account's label; null when available with nothing to show
  /// (iCloud). Throws when the account is not usable.
  Future<String?> _availableLabel() async =>
      switch (await _backend.availability()) {
        CloudAvailable(:final accountLabel) => accountLabel,
        CloudSignedOut() =>
          throw const BackupRelayException(BackupRelayError.signedOut),
        CloudUnavailable() =>
          throw const BackupRelayException(BackupRelayError.cloudUnavailable),
      };

  /// Attaches, uploads this device's slot and merges every other one.
  Future<void> _join(String? label) async {
    _accountLabel.value = label;
    _attach();
    await _engine.uploadNow(force: true);
    await _engine.attempt(() => _engine.pollOnce(full: true));
  }

  void _attach() => _engine.attach(
        _transport,
        readCursor: () => _meta.cloudCursor(kind.name),
        writeCursor: (c) => _meta.setCloudCursor(kind.name, c),
      );

  Future<void> _deleteAll({bool keepOwn = false}) async {
    final listing = await _transport.list();
    for (final s in listing?.slots ?? const <SlotInfo>[]) {
      if (keepOwn && s.slotId == _transport.ownSlotId) continue;
      await _transport.delete(s.slotId);
    }
  }

  Future<void> _leave() async {
    await _engine.detach();
    await _forgetStore();
    _accountLabel.value = null;
    _engine.setStatus(const BackupOff());
  }

  /// Forgets what was known of a store (merged versions, device names,
  /// offers, the cursor), when joining or leaving one.
  Future<void> _forgetStore() async {
    await _meta.clearMergedSeqs();
    await _meta.clearSlotNames();
    await _meta.clearOffers();
    await _meta.setCloudCursor(kind.name, null);
    _engine.refreshOffers();
  }

  /// A viewer's operation, in the engine's queue. A signed-out or
  /// unreachable account while syncing becomes the status (and halts, as a
  /// background failure would) before the error is rethrown.
  Future<T> _userOp<T>(Future<T> Function() op) => _engine.serialise(() async {
        try {
          return await op();
        } on BackupRelayException catch (e) {
          if (enabled &&
              (e.kind == BackupRelayError.signedOut ||
                  e.kind == BackupRelayError.cloudUnavailable)) {
            _engine.reportFailure(e.kind, e);
          }
          rethrow;
        }
      });
}
