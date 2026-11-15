export 'backup_status.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../auth/auth_storage.dart';
import 'backup_identity.dart';
import 'backup_meta_store.dart';
import 'backup_records.dart';
import 'backup_relay_client.dart';
import 'backup_snapshot.dart';
import 'backup_status.dart';
import 'backup_vault_ops.dart';
import 'backup_vault_state.dart';
import 'recovery_key.dart';
import 'relay_slot_transport.dart';
import 'slot_sync_engine.dart';
import 'vault_crypto.dart';

/// The vault this device is in and the one pairing offered it.
typedef VaultChoice = ({String current, String offered});

/// The relay backup: this device's slot of the end-to-end encrypted vault
/// and the vault's member changes. Uploading, polling, merging, backoff and
/// offers run in a [SlotSyncEngine] over a [RelaySlotTransport] of the
/// joined vault; this service owns the vault state, the recovery key, the
/// members and pairing. Free of Riverpod: `backupSyncServiceProvider` wires
/// the triggers ([markDirty], [poll], [flush]) and the stores.
///
/// Every relay sequence runs one at a time through the engine's queue, so
/// the vault state (own seq, epoch, keys) is never read and written by two
/// at once.
class BackupSyncService {
  BackupSyncService({
    required BackupRelayClient relay,
    required AuthStorage authStorage,
    required BackupMetaStore meta,
    required BackupSnapshot snapshot,
    required Future<String> Function() deviceName,
    required String platform,
    DateTime Function()? clock,
    String? Function()? localNodeId,
    Future<void> Function(Duration)? delay,
  })  : _relay = relay,
        _ops = BackupVaultOps(relay),
        _auth = authStorage,
        _store = BackupVaultStateStore(authStorage),
        _meta = meta,
        _deviceName = deviceName,
        _platform = platform,
        _clock = clock ?? DateTime.now,
        _localNodeId = localNodeId,
        _delay = delay ?? Future<void>.delayed {
    _engine = SlotSyncEngine(
      meta: meta,
      snapshot: snapshot,
      deviceName: deviceName,
      platform: platform,
      clock: _clock,
      beforeApply: _recordSlotClaims,
      beforeUpload: () async {
        final identity = _identity;
        if (identity != null) await _recordOwnNode(identity);
      },
      afterUpload: _ownUploaded,
      afterPoll: (_) async {
        final t = _transport;
        final m = t?.lastManifest;
        if (t != null && m != null) await _publishMembers(m, t.ownSlotId);
      },
      handleFatal: (e) => _gone(e) ? _leave(const BackupRemoved()) : null,
    );
  }

  static const debounce = SlotSyncEngine.debounce;
  static const pollInterval = SlotSyncEngine.pollInterval;
  static const maxBackoff = SlotSyncEngine.maxBackoff;
  static const maxSlotBytes = RelaySlotTransport.maxSlotBytes;

  final BackupRelayClient _relay;
  final BackupVaultOps _ops;
  final AuthStorage _auth;
  final BackupVaultStateStore _store;
  final BackupMetaStore _meta;
  final Future<String> Function() _deviceName;
  final String _platform;
  final DateTime Function() _clock;

  /// Uploads, polls, merges, backs off and keeps the offers, over
  /// [_transport] while in a vault.
  late final SlotSyncEngine _engine;

  /// The joined vault as a slot store, null while off. Owns the vault state
  /// from [_join] until [_detach].
  RelaySlotTransport? _transport;

  /// This device's p2p node id, null while p2p is not up. Recorded with
  /// the own slot id so the group record maps every member.
  final String? Function()? _localNodeId;

  /// Waits between the manifest reads of [adoptVault].
  final Future<void> Function(Duration) _delay;

  /// The joiner reads the offered vault's manifest this many more times
  /// when it is not listed yet, [adoptRetryDelay] times the attempt apart.
  static const adoptRetries = 3;
  static const adoptRetryDelay = Duration(milliseconds: 500);

  final _recoveryMismatch = ValueNotifier<bool>(false);
  final _unsavedKey = ValueNotifier<bool>(false);
  late final _joinedNotice = ValueNotifier<bool>(_meta.joinedNoticePending);
  final _vaultChoice = ValueNotifier<VaultChoice?>(null);

  ValueListenable<BackupStatus> get status => _engine.status;

  /// True from the moment pairing joined this device to its group's vault
  /// until [acknowledgeJoinedNotice]: "This device is now backed up with
  /// your group".
  ValueListenable<bool> get joinedNotice => _joinedNotice;
  bool get showJoinedNotice => _joinedNotice.value;

  /// Set when pairing offered a vault while this device was already in
  /// another one: the viewer picks with [resolveVaultChoice].
  ValueListenable<VaultChoice?> get pendingVaultChoice => _vaultChoice;

  /// Slot ids whose last download could not be opened or decoded.
  ValueListenable<Set<String>> get unreadableSlots => _engine.unreadableSlots;

  /// Slots whose device moved its backup to another store: slot id to the
  /// store id (`icloud`, `gdrive`).
  ValueListenable<Map<String, String>> get movedSlots => _engine.movedSlots;

  /// True while a listed slot was written by a newer app version.
  ValueListenable<bool> get newerVersionSeen => _engine.newerVersionSeen;

  /// True when the recovery key this device keeps is not the vault's (it
  /// was replaced from another device, or a replacement here was lost): the
  /// key shown would not restore the backup.
  ValueListenable<bool> get recoveryKeyMismatch => _recoveryMismatch;

  /// True while the recovery key this device keeps replaced the old one and
  /// the viewer has not pressed Done on the sheet showing it, as when the
  /// relay took a new key but the reply was lost or the app died first.
  /// Cleared by [acknowledgeNewRecoveryKey], or by leaving the vault.
  ValueListenable<bool> get unsavedRecoveryKey => _unsavedKey;

  /// Recovery signer public keys by key text, so a poll does not derive
  /// them every time.
  final _recoverySigners = <String, Uint8List?>{};

  /// Device names from the slots read so far, by slot id. Kept in the meta
  /// store, so they outlive a restart.
  Map<String, String> get slotDeviceNames => _meta.slotNames();

  final _members = ValueNotifier<List<BackupMemberInfo>>(const []);
  final _removals = ValueNotifier<List<PendingRemoval>>(const []);

  /// Every device in the vault, this one first, as of the last manifest
  /// read. Empty while off.
  ValueListenable<List<BackupMemberInfo>> get members => _members;

  /// Accounts other devices backed up that this one has not added or
  /// dismissed.
  ValueListenable<List<PendingAccountOffer>> get pendingOffers =>
      _engine.pendingOffers;

  /// Devices revoked from the p2p group that are still in the vault: each
  /// can read the backup until [removeMember] takes it out.
  ValueListenable<List<PendingRemoval>> get pendingRemovals => _removals;

  /// The vault state while no transport owns it: loaded but not joined,
  /// or saved before [_join].
  BackupVaultState? _stored;

  /// The transport's state while joined, else what was stored.
  BackupVaultState? get _state => _transport?.state ?? _stored;

  BackupIdentity? _identity;
  bool _disposed = false;

  /// Whether this device is in a vault. Read by the settings screen.
  bool get enabled => _state != null;

  /// The recovery key text this device keeps, null when off.
  String? get recoveryKeyText => _state?.recoveryKeyText;

  bool get _active => _state != null && !_engine.halted && !_disposed;

  int get _nowMs => _clock().millisecondsSinceEpoch;

  // Lifecycle

  /// Loads the vault state and, when in a vault, polls and schedules the
  /// periodic poll. Clears an earlier [BackupUnavailable]. A [dormant]
  /// vault is left alone: this device backs up to a cloud store.
  Future<void> start() => _engine.serialise(() async {
        _engine.halted = false;
        if (_transport != null) await _detach();
        if (dormant) {
          _stored = null;
          return _set(const BackupOff());
        }
        try {
          _stored = await _store.load();
          if (_stored == null) return _set(const BackupOff());
          _identity = await BackupIdentity.loadOrCreate(_auth);
        } catch (e) {
          debugPrint(
              '[Backup] Could not load the backup state: ${e.runtimeType}');
          return _set(
              BackupError(BackupRelayError.server, _state?.lastSuccessMs));
        }
        _publishUnsavedKey();
        await _join(_stored!, _identity!);
        // A change made just before the app was killed may never have gone
        // up.
        markDirty();
        // Unconditional, so the recovery key check (in-memory) runs once
        // per launch even when nothing changed since the stored ETag.
        unawaited(
            _engine.background(() => _engine.pollOnce(conditional: false)));
      });

  void dispose() {
    _disposed = true;
    _engine.dispose();
    unawaited(_transport?.close());
    _recoveryMismatch.dispose();
    _unsavedKey.dispose();
    _joinedNotice.dispose();
    _vaultChoice.dispose();
    _members.dispose();
    _removals.dispose();
  }

  // Triggers

  /// A backed-up record changed. Uploads at most once per [debounce].
  void markDirty() => _engine.markDirty();

  /// Uploads a pending change now, as the app goes to the background.
  Future<void> flush() => _engine.flush();

  /// Reads the manifest and merges every slot that changed. A poll asked
  /// for while one is still waiting its turn joins it.
  Future<void> poll() => _engine.poll();

  // Enable and restore

  /// A new recovery key. Contacts nothing: the vault is created by
  /// [confirmEnable] once the viewer has saved the key.
  Future<RecoveryKey> prepareEnable() async => RecoveryKey.generate();

  /// Creates the vault with this device and [key]'s recovery member at
  /// epoch 1, then uploads this device's slot.
  Future<void> confirmEnable(RecoveryKey key) => _userOp(() async {
        if (_state != null) throw StateError('backup is already on');
        final identity = await _loadIdentity();
        final recovery = await RecoveryMember.of(key);
        final vaultKey = randomVaultKey();
        final vaultId = await _ops.createVault(identity, recovery, vaultKey);
        final state = BackupVaultState(
          vaultId: vaultId,
          epoch: 1,
          keysByEpoch: {1: vaultKey},
          recoveryKeyText: key.display,
          ownSeq: 0,
        );
        try {
          await _save(state);
        } catch (_) {
          _stored = null;
          _set(const BackupError(BackupRelayError.server, null));
          // Nothing on this device knows the vault: free its lookup hash.
          await _relay
              .deleteVault(vaultId, identity.signer)
              .catchError((Object _) {});
          rethrow;
        }
        await _join(state, identity);
        _setMembers(
            [BackupMemberInfo(slotId: identity.slotId, isThisDevice: true)]);
        await _engine.uploadNow(force: true);
      });

  /// Finds [keyText]'s vault and reads every slot, as its recovery member.
  /// Changes nothing on the device or the relay.
  Future<RestorePreview> previewRestore(String keyText) => _userOp(
        () async {
          final recovery = await RecoveryMember.of(RecoveryKey.parse(keyText));
          return _ops.preview(recovery);
        },
        ownVault: false,
      );

  /// Joins [preview]'s vault (added by the recovery member, no rotation),
  /// applies its records in restore mode, and uploads this device's slot.
  /// Throws [BackupAlreadyOnException], touching nothing, when this device
  /// is already in a vault.
  Future<ApplyResult> commitRestore(RestorePreview preview) =>
      _userOp(() async {
        if (_state != null) throw const BackupAlreadyOnException();
        final identity = await _loadIdentity();
        final signer =
            backupB64((await identity.signer.extractPublicKey()).bytes);
        final member = preview.manifest.members
            .any((m) => !m.recovery && backupB64(m.signer) == signer);
        final joined = member
            ? (epoch: preview.epoch, vaultKey: preview.vaultKey)
            : await _ops.addSelfWithRecovery(
                vaultId: preview.vaultId,
                recovery: preview.recovery,
                identity: identity,
                epoch: preview.epoch,
                vaultKey: preview.vaultKey,
              );
        final own = preview.manifest.slots
            .where((s) => s.slotId == identity.slotId)
            .firstOrNull;
        final state = BackupVaultState(
          vaultId: preview.vaultId,
          epoch: joined.epoch,
          keysByEpoch: {joined.epoch: joined.vaultKey},
          recoveryKeyText: preview.recovery.key.display,
          ownSeq: own?.seq ?? 0,
        );
        try {
          await _save(state);
        } catch (_) {
          _stored = null;
          _set(const BackupError(BackupRelayError.server, null));
          rethrow;
        }
        await _meta.clearMergedSeqs();
        final result =
            await _engine.apply(preview.payloads, BackupApplyMode.restore);
        for (final e in preview.slotSeqs.entries) {
          await _meta.setMergedVersion(e.key, '${e.value}');
        }
        for (final e in preview.payloads.entries) {
          await _engine.rememberName(e.key, e.value.deviceName);
        }
        _engine.refreshOffers();
        await _publishMembers(preview.manifest, identity.slotId);
        await _join(state, identity);
        await _engine.uploadNow(force: true);
        return result;
      });

  // Pending accounts

  /// Adds an account another device backed up. Polls first when its record
  /// is no longer in memory (after a restart).
  Future<void> acceptPendingAccount(String accountId) =>
      _userOp(() => _engine.acceptOffer(accountId));

  Future<void> dismissPendingAccount(String accountId) =>
      _engine.dismissOffer(accountId);

  // Member changes

  /// Removes the member owning [slotId] and, in the same rotation, replaces
  /// the recovery key: a fresh vault key is sealed to every remaining
  /// member and the new recovery member. The removed device may hold the
  /// old recovery key (it created the vault, restored with it or generated
  /// it), so keeping that key would let it read on. Returns the new key,
  /// which the viewer must save.
  Future<RecoveryKey> removeMember(String slotId) => _userOp(() async {
        final (_, identity) = _require();
        if (slotId == identity.slotId) {
          throw StateError('use disable() to remove this device');
        }
        final key = await _replaceRecoveryKey(removeSlotId: slotId);
        _setMembers([
          for (final m in _members.value)
            if (m.slotId != slotId) m,
        ]);
        await _forgetRemovalsOf(slotId);
        return key;
      });

  /// Replaces the recovery key (and rotates). The old key stops working.
  Future<RecoveryKey> regenerateRecoveryKey() =>
      _userOp(() => _replaceRecoveryKey());

  /// The viewer pressed Done on the sheet showing the new recovery key:
  /// [unsavedRecoveryKey] clears, here and across restarts.
  Future<void> acknowledgeNewRecoveryKey() => _engine.serialise(() async {
        final state = _state;
        if (state == null || !state.recoveryKeyUnacknowledged) return;
        try {
          await _save(state.copyWith(recoveryKeyUnacknowledged: false));
        } on StateError catch (e) {
          // Shown again on the next start: better than losing the prompt.
          debugPrint('[Backup] Could not save the acknowledgement: $e');
        }
      });

  /// A rotation to a new recovery key, removing [removeSlotId]'s member in
  /// it when given, then this device's upload under the new epoch.
  Future<RecoveryKey> _replaceRecoveryKey({String? removeSlotId}) async {
    final key = RecoveryKey.generate();
    final (state, _) = _require();
    // Kept before the relay call: if the relay takes the new key and the
    // reply is lost, the next poll promotes it (see _reconcileRecovery)
    // instead of leaving the dead old key shown.
    await _save(state.copyWith(
      pendingRecoveryKeyText: () => key.display,
      manifestEtag: () => null,
    ));
    await _rotate(
        removeSlotId: removeSlotId, newRecovery: await RecoveryMember.of(key));
    await _engine.uploadNow(force: true);
    return key;
  }

  /// Deletes the vault for every member, then turns backup off here.
  Future<void> deleteBackup() => _userOp(() async {
        final (state, identity) = _require();
        await _ignoreGone(
            () => _relay.deleteVault(state.vaultId, identity.signer));
        await _leave(const BackupOff());
      });

  /// Leaves the vault: removes this device with a rotation, or deletes the
  /// vault when no other device is in it. Local data stays.
  Future<void> disable() => _userOp(() async {
        if (_state == null) return _set(const BackupOff());
        final (state, identity) = _require();
        await _leaveOnRelay(state.vaultId, identity);
        await _leave(const BackupOff());
      });

  /// Moves this device's backup to the store [to] (a store id such as
  /// `gdrive`): rewrites its slot as an empty stub naming [to], so the other
  /// members offer to follow, and stops syncing. The vault state stays on
  /// disk, [dormant], and this device stays a member, so the stub stays
  /// readable to the others. [deleteOld] deletes the vault for every member
  /// instead, as [deleteBackup] does. The caller enables the new store.
  Future<void> switchAway(String to, {required bool deleteOld}) =>
      _userOp(() async {
        final (state, identity) = _require();
        if (deleteOld) {
          await _ignoreGone(
              () => _relay.deleteVault(state.vaultId, identity.signer));
          return _leave(const BackupOff());
        }
        await _requireTransport().writeOwn(BackupPayload(
          deviceName: await _deviceName(),
          platform: _platform,
          createdAt: _nowMs,
          records: const [],
          movedTo: to,
        ));
        await _meta.setRelayDormant(true);
        await _detach();
        _stored = null;
        _setMismatch(false);
        _publishUnsavedKey();
        _setMembers(const []);
        _setChoice(null);
        _set(const BackupOff());
      });

  /// Whether the vault on disk is dormant (see [switchAway]).
  bool get dormant => _meta.relayDormant;

  /// Syncs the [dormant] vault again, as when the viewer switches back to
  /// the relay: its next upload replaces the moved stub.
  Future<void> resumeDormant() async {
    await _meta.setRelayDormant(false);
    await start();
  }

  /// Stops background syncing, staying in the vault, while another store
  /// comes up (see `SlotSyncEngine.pause`).
  Future<void> pauseSync() => _engine.pause();

  /// Undoes [pauseSync].
  void resumeSync() => _engine.unpause();

  /// Takes this device out of [vaultId] on the relay: a rotation that
  /// removes it, or deleting the vault when no other device is in it. A
  /// vault already gone, or this device already out, is done.
  Future<void> _leaveOnRelay(String vaultId, BackupIdentity identity) =>
      _ignoreGone(() async {
        final m = (await _relay.manifest(vaultId, identity.signer))!;
        final others =
            m.members.where((x) => !x.recovery && x.slotId != identity.slotId);
        if (others.isEmpty) {
          await _relay.deleteVault(vaultId, identity.signer);
        } else {
          await _ops.rotate(
              vaultId: vaultId,
              signer: identity.signer,
              removeSlotId: identity.slotId);
        }
      });

  // Pairing

  /// This device's backup public keys (base64url signer and box key), sent
  /// in a pairing request so the host can add it to the group's vault.
  /// Creates the identity on first use; null when that fails, which never
  /// fails the pairing.
  Future<({String signer, String box})?> pairKeys() async {
    try {
      final identity = _identity ??= await BackupIdentity.loadOrCreate(_auth);
      return (
        signer: backupB64((await identity.signer.extractPublicKey()).bytes),
        box: backupB64((await identity.box.extractPublicKey()).bytes),
      );
    } catch (e) {
      debugPrint('[Backup] No backup keys for pairing: ${e.runtimeType}');
      return null;
    }
  }

  /// The host side of pairing: adds the joiner owning [signerB64] and
  /// [boxB64] to this device's vault at the current epoch (no rotation),
  /// records [nodeId]'s slot for a later revocation, and returns the vault
  /// id. Null when backup is off, the add failed, or [deadline] (wall
  /// clock) passed before the relay write: the host has stopped waiting by
  /// then, and a late write would leave a member that never adopts the
  /// vault. Pairing goes on without it.
  ///
  /// A signer already in the vault is not recorded against [nodeId]: the
  /// joiner proved nothing about owning it, and a revocation must not
  /// reach another member's slot. That member's own group record says
  /// which node it is.
  Future<String?> addMemberForPair(String signerB64, String boxB64,
          {String? nodeId, DateTime? deadline}) =>
      _engine.serialise(() async {
        bool late() => deadline != null && DateTime.now().isAfter(deadline);
        if (!_active || late()) return null;
        try {
          final signerPub = backupUnb64(signerB64);
          final boxPub = backupUnb64(boxB64);
          if (signerPub.length != 32 || boxPub.length != 32) return null;
          final (_, identity) = _require();
          final transport = _requireTransport();
          for (var attempt = 0;; attempt++) {
            final vaultId = _state!.vaultId;
            final m = (await _relay.manifest(vaultId, identity.signer))!;
            final state = await transport.adoptEpoch(m);
            final listed = m.members
                .any((x) => !x.recovery && listEquals(x.signer, signerPub));
            if (listed) return vaultId;
            if (late()) return null;
            try {
              await _ops.addMember(
                vaultId: vaultId,
                signer: identity.signer,
                epoch: state.epoch,
                vaultKey: state.keysByEpoch[state.epoch]!,
                memberSigner: signerPub,
                memberBox: boxPub,
              );
            } on BackupRelayException catch (e) {
              if (e.kind != BackupRelayError.conflict || attempt > 0) {
                rethrow;
              }
              continue;
            }
            if (nodeId != null) {
              await _meta.setNodeToSlot(
                  nodeId, VaultCrypto.slotIdFor(signerPub));
              markDirty();
            }
            return vaultId;
          }
        } catch (e) {
          debugPrint('[Backup] Paired device not added: ${e.runtimeType}');
          return null;
        }
      });

  /// The joiner side of pairing: takes up [vaultId], which the host just
  /// added this device to, and raises [joinedNotice]. Uploading this
  /// device's slot and merging the group's is queued, not awaited, so
  /// pairing does not wait on a 4 MB transfer. A device already in another
  /// vault is not switched: [pendingVaultChoice] asks the viewer instead.
  Future<void> adoptVault(String vaultId) => _engine.serialise(() async {
        // Null before start() ran: read the stored state, so a vault this
        // device is already in is never overwritten. A load that fails
        // aborts the adoption. Not kept in memory: start() loads it with
        // the identity that uploads need.
        final current = _state ?? await _store.load();
        if (current != null) {
          if (current.vaultId != vaultId) {
            _setChoice((current: current.vaultId, offered: vaultId));
          }
          return;
        }
        final identity = await _loadIdentity();
        await _switchTo(await _openAsMember(vaultId, identity), identity);
        await _meta.setJoinedNoticePending(true);
        if (!_disposed) _joinedNotice.value = true;
        unawaited(_engine.background(_uploadAndMerge));
      });

  /// Completes once every operation queued so far has run.
  @visibleForTesting
  Future<void> settled() => _engine.serialise(() async {});

  void acknowledgeJoinedNotice() {
    if (!_disposed) _joinedNotice.value = false;
    unawaited(_meta.setJoinedNoticePending(false));
  }

  /// Settles [pendingVaultChoice]. Keeping the offered vault moves this
  /// device into it (its records are local, so they go up with its slot)
  /// and then leaves the old one, deleting it when this device was its
  /// only one. Keeping the current vault takes this device out of the
  /// offered one (best effort), where the host had added it.
  Future<void> resolveVaultChoice({required bool keepOffered}) =>
      _engine.serialise(() async {
        final choice = _vaultChoice.value;
        if (choice == null) return;
        if (!keepOffered) {
          // Cleared first: leaving the offered vault is best effort, and
          // an identity that does not load must not leave the choice up.
          _setChoice(null);
          if (choice.offered == choice.current) return;
          try {
            await _leaveOnRelay(choice.offered, await _loadIdentity());
          } catch (e) {
            debugPrint('[Backup] Offered vault not left: ${e.runtimeType}');
          }
          return;
        }
        final identity = await _loadIdentity();
        final BackupVaultState next;
        try {
          next = await _openAsMember(choice.offered, identity);
        } on BackupRelayException catch (e) {
          // This device is no longer in the offered vault: nothing to pick.
          if (_gone(e)) _setChoice(null);
          rethrow;
        }
        _setChoice(null);
        await _switchTo(next, identity);
        await _engine.attempt(_uploadAndMerge);
        if (choice.current == choice.offered) return;
        try {
          await _leaveOnRelay(choice.current, identity);
        } catch (e) {
          debugPrint('[Backup] Old vault not left: ${e.runtimeType}');
        }
      });

  /// Records that p2p node [nodeId] (named [deviceName] in the group) was
  /// revoked, so [pendingRemovals] asks the viewer to remove it from the
  /// vault too. Writes nothing to the relay: removing a device replaces the
  /// recovery key, which the viewer has to save, so it is never done
  /// silently. The node's slot is resolved by [_slotForNode]; an entry
  /// that names no slot yet waits for a group record that does.
  Future<void> notePeerRevoked(String nodeId, {String? deviceName}) async {
    if (_state == null) return;
    final slotId = _slotForNode(nodeId);
    if (slotId != null && slotId == _identity?.slotId) return;
    await _meta.setPendingRemoval(nodeId,
        slotId: slotId, deviceName: deviceName);
    _publishRemovals();
  }

  /// The vault slot p2p node [nodeId] owns, from this device's own pairing
  /// record or from that slot's own group record claiming the node, never
  /// from what one member says of another's slot. Null when no slot claims
  /// it (it never joined the vault) or two do: either could be the wrong
  /// device.
  String? _slotForNode(String nodeId) {
    final wanted = nodeId.toLowerCase();
    final slots = <String>{
      for (final e in _meta.nodeToSlot().entries)
        if (e.key.toLowerCase() == wanted) e.value,
      for (final e in _meta.slotClaims().entries)
        if (e.value.any((n) => n.toLowerCase() == wanted)) e.key,
    };
    return slots.length == 1 ? slots.single : null;
  }

  /// Settles the stored pending removals against [m]: resolves an entry's
  /// slot once a trusted record names it, and drops an entry whose slot is
  /// no longer a member (removed here or by another device) or is this
  /// device's own.
  Future<void> _reconcileRemovals(BackupManifest m, String ownSlotId) async {
    final memberSlots = {
      for (final x in m.members)
        if (!x.recovery) x.slotId,
    };
    for (final MapEntry(key: nodeId, value: e)
        in _meta.pendingRemovals().entries) {
      final slotId = e.slotId ?? _slotForNode(nodeId);
      if (slotId == null) continue;
      if (slotId == ownSlotId || !memberSlots.contains(slotId)) {
        await _meta.removePendingRemoval(nodeId);
      } else if (e.slotId == null) {
        await _meta.setPendingRemoval(nodeId,
            slotId: slotId, deviceName: e.deviceName);
      }
    }
  }

  Future<void> _forgetRemovalsOf(String slotId) async {
    for (final MapEntry(key: nodeId, value: e)
        in _meta.pendingRemovals().entries) {
      if ((e.slotId ?? _slotForNode(nodeId)) == slotId) {
        await _meta.removePendingRemoval(nodeId);
      }
    }
    _publishRemovals();
  }

  /// Publishes the stored removals whose slot is in the member list.
  void _publishRemovals() {
    if (_disposed) return;
    final members = {
      for (final m in _members.value)
        if (!m.isThisDevice) m.slotId: m,
    };
    final out = <PendingRemoval>[];
    for (final MapEntry(key: nodeId, value: e)
        in _meta.pendingRemovals().entries) {
      final slotId = e.slotId ?? _slotForNode(nodeId);
      final member = members[slotId];
      if (slotId == null || member == null) continue;
      if (out.any((r) => r.slotId == slotId)) continue;
      out.add(PendingRemoval(
        nodeId: nodeId,
        slotId: slotId,
        deviceName: member.deviceName ?? e.deviceName,
      ));
    }
    out.sort((a, b) => a.nodeId.compareTo(b.nodeId));
    _removals.value = List.unmodifiable(out);
  }

  /// Reads [vaultId]'s manifest as [identity], again up to [adoptRetries]
  /// times while this device is not listed yet (the host's add can land
  /// after its pairing reply), and opens this device's envelope.
  Future<BackupVaultState> _openAsMember(
      String vaultId, BackupIdentity identity) async {
    for (var attempt = 0;; attempt++) {
      BackupManifest? m;
      try {
        m = await _relay.manifest(vaultId, identity.signer);
      } on BackupRelayException catch (e) {
        if (e.kind != BackupRelayError.notMember || attempt >= adoptRetries) {
          rethrow;
        }
      }
      if (m != null &&
          m.members.any((x) => !x.recovery && x.slotId == identity.slotId)) {
        final Uint8List key;
        try {
          key = await VaultCrypto.openEnvelope(
            box: identity.box,
            envelope: m.envelope,
            vaultId: vaultId,
            epoch: m.epoch,
          );
        } on VaultCryptoException {
          throw const BackupRelayException(BackupRelayError.invalid);
        }
        final own =
            m.slots.where((s) => s.slotId == identity.slotId).firstOrNull;
        return BackupVaultState(
          vaultId: vaultId,
          epoch: m.epoch,
          keysByEpoch: {m.epoch: key},
          recoveryKeyText: null,
          ownSeq: own?.seq ?? 0,
        );
      }
      if (attempt >= adoptRetries) {
        throw const BackupRelayException(BackupRelayError.notMember);
      }
      await _delay(adoptRetryDelay * (attempt + 1));
    }
  }

  /// Makes [state] this device's vault: what was known of another vault
  /// (merged seqs, slot names, failures) is dropped first.
  Future<void> _switchTo(
      BackupVaultState state, BackupIdentity identity) async {
    await _detach();
    _setMismatch(false);
    _setMembers(const []);
    await _meta.clearMergedSeqs();
    await _meta.clearSlotClaims();
    await _meta.clearSlotNames();
    await _meta.clearOffers();
    await _meta.clearPendingRemovals();
    _engine.refreshOffers();
    try {
      await _save(state);
    } catch (_) {
      _stored = null;
      _set(const BackupError(BackupRelayError.server, null));
      rethrow;
    }
    await _join(state, identity);
  }

  Future<void> _uploadAndMerge() async {
    await _engine.uploadOnce(force: true);
    await _engine.pollOnce(full: true);
  }

  void _setChoice(VaultChoice? choice) {
    if (!_disposed) _vaultChoice.value = choice;
  }

  // Engine hooks

  /// This device's member entry takes the upload's time.
  void _ownUploaded() {
    final at = _state?.lastSuccessMs;
    _setMembers([
      for (final m in _members.value)
        m.isThisDevice
            ? BackupMemberInfo(
                slotId: m.slotId,
                isThisDevice: true,
                deviceName: m.deviceName,
                lastUploadMs: at,
              )
            : m,
    ]);
  }

  /// [m]'s devices (not the recovery member), this device first and listed
  /// even when the manifest predates its joining.
  Future<void> _publishMembers(BackupManifest m, String ownSlotId) async {
    await _reconcileRemovals(m, ownSlotId);
    final names = _meta.slotNames();
    final updated = {for (final s in m.slots) s.slotId: s.updatedAt};
    BackupMemberInfo info(String slotId) => BackupMemberInfo(
          slotId: slotId,
          isThisDevice: slotId == ownSlotId,
          deviceName: names[slotId],
          lastUploadMs: updated[slotId],
        );
    _setMembers([
      info(ownSlotId),
      for (final x in m.members)
        if (!x.recovery && x.slotId != ownSlotId) info(x.slotId),
    ]);
  }

  void _setMembers(List<BackupMemberInfo> members) {
    if (_disposed) return;
    _members.value = List.unmodifiable(members);
    _publishRemovals();
  }

  /// Records each slot's p2p node claims before its payload is applied.
  Future<void> _recordSlotClaims(Map<String, BackupPayload> payloads) async {
    for (final MapEntry(key: slotId, value: p) in payloads.entries) {
      // Each slot's group record, not only the winning one, but only for
      // the nodes it says are its own: a member's word about another
      // member's slot would let it aim a revocation at that member.
      final group = p.records
          .whereType<GroupBackupRecord>()
          .where((r) => !r.deleted)
          .firstOrNull;
      if (group != null) {
        await _meta.setSlotClaim(slotId, {
          for (final MapEntry(:key, :value) in group.nodeToSlot.entries)
            if (value == slotId) key,
        });
      }
    }
  }

  // Recovery key

  /// Settles a recovery key replacement whose outcome was not seen: the
  /// pending key wins when the manifest names its signer, else it is
  /// dropped. Then flags a stored key that is not the vault's.
  Future<BackupVaultState> _reconcileRecovery(
      BackupVaultState state, BackupManifest m) async {
    final pending = state.pendingRecoveryKeyText;
    if (pending != null) {
      final took = await _isRecoverySigner(pending, m.recoverySigner);
      // A promoted key was never shown (the reply was lost or the app died
      // first): flagged until the viewer saves it.
      state = state.copyWith(
        recoveryKeyText: took ? pending : null,
        pendingRecoveryKeyText: () => null,
        recoveryKeyUnacknowledged: took ? true : null,
      );
      await _save(state);
    }
    // A device that joined by pairing keeps no key, so none can be wrong.
    final kept = state.recoveryKeyText;
    _setMismatch(
        kept != null && !await _isRecoverySigner(kept, m.recoverySigner));
    return state;
  }

  /// Records this device's node id against its slot id, so the group
  /// record it uploads lets another member revoke it.
  Future<void> _recordOwnNode(BackupIdentity identity) async {
    final nodeId = _localNodeId?.call();
    if (nodeId == null) return;
    if (_meta.nodeToSlot()[nodeId] != identity.slotId) {
      await _meta.setNodeToSlot(nodeId, identity.slotId);
    }
  }

  Future<bool> _isRecoverySigner(String keyText, List<int> signer) async {
    if (!_recoverySigners.containsKey(keyText)) {
      Uint8List? pub;
      try {
        final kp = await RecoveryKey.parse(keyText).signer();
        pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
      } on FormatException {
        pub = null;
      }
      _recoverySigners[keyText] = pub;
    }
    final pub = _recoverySigners[keyText];
    return pub != null && listEquals(pub, signer);
  }

  void _setMismatch(bool value) {
    if (!_disposed) _recoveryMismatch.value = value;
  }

  // Rotation

  /// Rotates after taking up the current epoch (so slots still at it stay
  /// readable), and saves the new key as soon as the relay accepted it.
  Future<Rotation?> _rotate(
      {String? removeSlotId, RecoveryMember? newRecovery}) async {
    var (state, identity) = _require();
    final m = (await _relay.manifest(state.vaultId, identity.signer))!;
    state = await _requireTransport().adoptEpoch(m);
    final rotation = await _ops.rotate(
      vaultId: state.vaultId,
      signer: identity.signer,
      removeSlotId: removeSlotId,
      newRecovery: newRecovery,
    );
    if (rotation == null) return null;
    await _save(_state!.copyWith(
      epoch: rotation.epoch,
      keysByEpoch: {..._state!.keysByEpoch, rotation.epoch: rotation.vaultKey},
      recoveryKeyText: newRecovery?.key.display,
      pendingRecoveryKeyText: newRecovery == null ? null : () => null,
      // Until the viewer presses Done on the sheet showing it.
      recoveryKeyUnacknowledged: newRecovery == null ? null : true,
      manifestEtag: () => null,
    ));
    if (newRecovery != null) _setMismatch(false);
    return rotation;
  }

  // State

  (BackupVaultState, BackupIdentity) _require() {
    final state = _state;
    final identity = _identity;
    if (state == null || identity == null) {
      throw StateError('backup is off');
    }
    return (state, identity);
  }

  RelaySlotTransport _requireTransport() {
    final transport = _transport;
    if (transport == null) throw StateError('backup is off');
    return transport;
  }

  Future<BackupIdentity> _loadIdentity() async {
    try {
      return _identity ??= await BackupIdentity.loadOrCreate(_auth);
    } on StateError {
      _set(const BackupError(BackupRelayError.server, null));
      rethrow;
    }
  }

  /// Persists [state] and makes it current, through the transport while
  /// joined so its state is never stale. A storage that cannot persist
  /// throws [StateError], which callers report as `Error(server)`.
  Future<void> _save(BackupVaultState state) async {
    final transport = _transport;
    if (transport != null) return transport.save(state);
    _stored = state;
    _publishUnsavedKey();
    await _store.save(state);
  }

  /// A pending key is not flagged: it may yet be dropped.
  void _publishUnsavedKey() {
    if (_disposed) return;
    final s = _state;
    _unsavedKey.value = s != null &&
        s.recoveryKeyUnacknowledged &&
        s.pendingRecoveryKeyText == null &&
        s.recoveryKeyText != null;
  }

  /// Makes [state] the joined vault: a [RelaySlotTransport] owns it from
  /// here, and the engine syncs over it (Idle, periodic poll).
  Future<void> _join(BackupVaultState state, BackupIdentity identity) async {
    // A vault made live (enabled, restored, adopted) is never dormant.
    if (dormant) await _meta.setRelayDormant(false);
    _identity = identity;
    final transport = RelaySlotTransport(
      relay: _relay,
      store: _store,
      identity: identity,
      state: state,
      nowMs: () => _nowMs,
    );
    transport
      ..beforeAdopt = ((m) => _reconcileRecovery(transport.state, m))
      ..onSaved = ((_) => _publishUnsavedKey());
    _transport = transport;
    _stored = null;
    _engine.attach(
      transport,
      lastSuccessMs: state.lastSuccessMs,
      // The manifest ETag lives in the vault state, as before the engine.
      readCursor: () => transport.state.manifestEtag,
      writeCursor: (etag) =>
          transport.save(transport.state.copyWith(manifestEtag: () => etag)),
    );
  }

  /// Hands the vault state back from the transport and stops the engine
  /// syncing over it.
  Future<void> _detach() async {
    final transport = _transport;
    if (transport != null) {
      _stored = transport.state;
      transport
        ..beforeAdopt = null
        ..onSaved = null;
      _transport = null;
      unawaited(transport.close());
    }
    await _engine.detach();
  }

  /// Clears `backup/vault` and the merged seqs; local data is kept.
  Future<void> _leave(BackupStatus next) async {
    await _detach();
    _stored = null;
    _setMismatch(false);
    _publishUnsavedKey();
    _setMembers(const []);
    _setChoice(null);
    if (!_disposed) _joinedNotice.value = false;
    await _store.clear();
    await _meta.setRelayDormant(false);
    await _meta.clearMergedSeqs();
    await _meta.clearSlotClaims();
    await _meta.clearSlotNames();
    await _meta.clearOffers();
    await _meta.clearPendingRemovals();
    _engine.refreshOffers();
    _publishRemovals();
    await _meta.setJoinedNoticePending(false);
    _set(next);
  }

  /// Runs [op], treating a vault that is already gone (or this device no
  /// longer a member of it) as done.
  Future<void> _ignoreGone(Future<void> Function() op) async {
    try {
      await op();
    } on BackupRelayException catch (e) {
      if (!_gone(e)) rethrow;
    }
  }

  static bool _gone(BackupRelayException e) =>
      e.kind == BackupRelayError.notMember ||
      (e.kind == BackupRelayError.notFound && e.code == 'vault_not_found');

  // Running operations

  /// An operation the viewer asked for: errors are rethrown to the caller
  /// after the status reflects a removal or a missing relay feature.
  ///
  /// The viewer acting is a retry: an earlier [BackupUnavailable] is lifted
  /// for the op, and stays lifted when it succeeds. A vault that is gone
  /// means this device was removed only when the op addressed this
  /// device's own vault ([ownVault]), not, say, a preview of another one.
  Future<T> _userOp<T>(Future<T> Function() op, {bool ownVault = true}) =>
      _engine.serialise(() async {
        final vaultId = _state?.vaultId;
        final wasHalted = _engine.halted;
        _engine.halted = false;
        try {
          final result = await op();
          if (wasHalted && !_engine.halted) {
            if (_state != null) _engine.ensurePolling();
            if (status.value is BackupUnavailable) {
              _state == null ? _set(const BackupOff()) : _engine.idle();
            }
          }
          return result;
        } on BackupRelayException catch (e) {
          if (ownVault &&
              vaultId != null &&
              _gone(e) &&
              _state?.vaultId == vaultId) {
            await _leave(const BackupRemoved());
          } else if (e.kind == BackupRelayError.unavailable) {
            _engine.halt();
          } else if (wasHalted) {
            _engine.halted = true;
          }
          rethrow;
        } catch (_) {
          if (wasHalted) _engine.halted = true;
          rethrow;
        }
      });

  void _set(BackupStatus s) => _engine.setStatus(s);
}
