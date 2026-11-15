export 'backup_status.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart' show SimpleKeyPair;
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
import 'vault_crypto.dart';

/// The vault this device is in and the one pairing offered it.
typedef VaultChoice = ({String current, String offered});

/// Uploads this device's slot of the end-to-end encrypted cloud backup,
/// polls and merges the other members' slots, and runs the vault's member
/// changes. Free of Riverpod: `backupSyncServiceProvider` wires the
/// triggers ([markDirty], [poll], [flush]) and the stores.
///
/// Every relay sequence runs one at a time, so the vault state (own seq,
/// epoch, keys) is never read and written by two at once.
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
        _snapshot = snapshot,
        _deviceName = deviceName,
        _platform = platform,
        _clock = clock ?? DateTime.now,
        _localNodeId = localNodeId,
        _delay = delay ?? Future<void>.delayed {
    // Filled here, not lazily: a lazy notifier could first be created by
    // dispose().
    _offers.value = meta.pendingAccounts();
  }

  static const debounce = Duration(minutes: 2);
  static const pollInterval = Duration(minutes: 15);
  static const maxBackoff = Duration(minutes: 30);
  static const maxSlotBytes = 4194304;

  final BackupRelayClient _relay;
  final BackupVaultOps _ops;
  final AuthStorage _auth;
  final BackupVaultStateStore _store;
  final BackupMetaStore _meta;
  final BackupSnapshot _snapshot;
  final Future<String> Function() _deviceName;
  final String _platform;
  final DateTime Function() _clock;

  /// This device's p2p node id, null while p2p is not up. Recorded with
  /// the own slot id so the group record maps every member.
  final String? Function()? _localNodeId;

  /// Waits between the manifest reads of [adoptVault].
  final Future<void> Function(Duration) _delay;

  /// The joiner reads the offered vault's manifest this many more times
  /// when it is not listed yet, [adoptRetryDelay] times the attempt apart.
  static const adoptRetries = 3;
  static const adoptRetryDelay = Duration(milliseconds: 500);

  final _status = ValueNotifier<BackupStatus>(const BackupOff());
  final _unreadable = ValueNotifier<Set<String>>(const {});
  final _recoveryMismatch = ValueNotifier<bool>(false);
  final _unsavedKey = ValueNotifier<bool>(false);
  late final _joinedNotice = ValueNotifier<bool>(_meta.joinedNoticePending);
  final _vaultChoice = ValueNotifier<VaultChoice?>(null);

  ValueListenable<BackupStatus> get status => _status;

  /// True from the moment pairing joined this device to its group's vault
  /// until [acknowledgeJoinedNotice]: "This device is now backed up with
  /// your group".
  ValueListenable<bool> get joinedNotice => _joinedNotice;
  bool get showJoinedNotice => _joinedNotice.value;

  /// Set when pairing offered a vault while this device was already in
  /// another one: the viewer picks with [resolveVaultChoice].
  ValueListenable<VaultChoice?> get pendingVaultChoice => _vaultChoice;

  /// Slot ids whose last download could not be opened or decoded.
  ValueListenable<Set<String>> get unreadableSlots => _unreadable;

  /// True when the recovery key this device keeps is not the vault's (it
  /// was replaced from another device, or a replacement here was lost): the
  /// key shown would not restore the backup.
  ValueListenable<bool> get recoveryKeyMismatch => _recoveryMismatch;

  /// True while the recovery key this device keeps replaced the old one and
  /// the viewer has not pressed Done on the sheet showing it, as when the
  /// relay took a new key but the reply was lost or the app died first.
  /// Cleared by [acknowledgeNewRecoveryKey], or by leaving the vault.
  ValueListenable<bool> get unsavedRecoveryKey => _unsavedKey;

  /// Slots that could not be read, by the seq that failed: not downloaded
  /// again until their seq changes.
  final _failedSlots = <String, int>{};

  /// Recovery signer public keys by key text, so a poll does not derive
  /// them every time.
  final _recoverySigners = <String, Uint8List?>{};

  /// Device names from the slots read so far, by slot id. Kept in the meta
  /// store, so they outlive a restart.
  Map<String, String> get slotDeviceNames => _meta.slotNames();

  final _members = ValueNotifier<List<BackupMemberInfo>>(const []);
  final _offers = ValueNotifier<List<PendingAccountOffer>>(const []);
  final _removals = ValueNotifier<List<PendingRemoval>>(const []);

  /// Every device in the vault, this one first, as of the last manifest
  /// read. Empty while off.
  ValueListenable<List<BackupMemberInfo>> get members => _members;

  /// Accounts other devices backed up that this one has not added or
  /// dismissed.
  ValueListenable<List<PendingAccountOffer>> get pendingOffers => _offers;

  /// Devices revoked from the p2p group that are still in the vault: each
  /// can read the backup until [removeMember] takes it out.
  ValueListenable<List<PendingRemoval>> get pendingRemovals => _removals;

  BackupVaultState? _state;
  BackupIdentity? _identity;

  /// The vault a [commitRestore] asked the relay to add this device to and
  /// then failed (or lost the reply), so running it again asks the relay
  /// whether it did instead of adding the device twice, which it refuses.
  String? _restoreTried;

  /// This device's key for [vaultId] when an earlier [commitRestore] of it
  /// may have joined: read from the relay as this device. Null when no
  /// earlier attempt ran or the relay says this device is not a member.
  Future<Rotation?> _joinedEarlier(
      String vaultId, BackupIdentity identity) async {
    if (_restoreTried != vaultId) return null;
    final BackupManifest m;
    try {
      m = (await _relay.manifest(vaultId, identity.signer))!;
    } on BackupRelayException catch (e) {
      if (e.kind == BackupRelayError.notMember) return null;
      rethrow;
    }
    return (
      epoch: m.epoch,
      vaultKey: await VaultCrypto.openEnvelope(
        box: identity.box,
        envelope: m.envelope,
        vaultId: vaultId,
        epoch: m.epoch,
      ),
    );
  }

  bool _halted = false;
  bool _disposed = false;
  bool _dirty = false;

  /// The last upload was refused as too large; a successful poll keeps
  /// showing that until an upload succeeds.
  bool _tooLarge = false;
  int _failures = 0;
  String? _uploadedHash;
  Timer? _debounceTimer;
  Timer? _pollTimer;
  Timer? _retryTimer;
  Future<void> _queue = Future.value();

  /// The latest merged account records, by account id, so an offer can be
  /// accepted: the offer itself holds no credentials.
  final _accountRecords = <String, AccountBackupRecord>{};

  /// Whether this device is in a vault. Read by the settings screen.
  bool get enabled => _state != null;

  /// The recovery key text this device keeps, null when off.
  String? get recoveryKeyText => _state?.recoveryKeyText;

  bool get _active => _state != null && !_halted && !_disposed;

  int get _nowMs => _clock().millisecondsSinceEpoch;

  // Lifecycle

  /// Loads the vault state and, when in a vault, polls and schedules the
  /// periodic poll. Clears an earlier [BackupUnavailable].
  Future<void> start() => _serialise(() async {
        _halted = false;
        try {
          _state = await _store.load();
          if (_state == null) return _set(const BackupOff());
          await _identityOnce();
        } catch (e) {
          debugPrint(
              '[Backup] Could not load the backup state: ${e.runtimeType}');
          return _set(
              BackupError(BackupRelayError.server, _state?.lastSuccessMs));
        }
        _publishUnsavedKey();
        _set(BackupIdle(_state!.lastSuccessMs));
        _startPolling();
        // A change made just before the app was killed may never have gone
        // up.
        markDirty();
        // Unconditional, so the recovery key check (in-memory) runs once
        // per launch even when nothing changed since the stored ETag.
        unawaited(_background(() => _pollOnce(conditional: false)));
      });

  void dispose() {
    _disposed = true;
    _cancelTimers();
    _status.dispose();
    _unreadable.dispose();
    _recoveryMismatch.dispose();
    _unsavedKey.dispose();
    _joinedNotice.dispose();
    _vaultChoice.dispose();
    _members.dispose();
    _offers.dispose();
    _removals.dispose();
  }

  // Triggers

  /// A backed-up record changed. Uploads at most once per [debounce].
  void markDirty() {
    if (!_active) return;
    _dirty = true;
    _debounceTimer ??= Timer(debounce, () {
      _debounceTimer = null;
      unawaited(_background(_uploadIfDirty));
    });
  }

  /// Uploads a pending change now, as the app goes to the background.
  Future<void> flush() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (!_active || !_dirty) return;
    await _background(_uploadIfDirty);
  }

  /// Reads the manifest and merges every slot that changed. A poll asked
  /// for while one is still waiting its turn joins it.
  Future<void> poll() {
    if (!_active) return Future.value();
    final waiting = _pendingPoll;
    if (waiting != null) return waiting;
    late final Future<void> mine;
    void release() {
      if (identical(_pendingPoll, mine)) _pendingPoll = null;
    }

    mine = _background(() {
      release();
      return _pollOnce();
    }).whenComplete(release);
    return _pendingPoll = mine;
  }

  Future<void>? _pendingPoll;

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
          _state = null;
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
        await _attempt(() => _upload(force: true));
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
  ///
  /// The records are applied before the vault state is saved, so a restore
  /// that fails part way leaves backup off and can simply run again: a rerun
  /// for the same vault first asks the relay whether the earlier attempt
  /// added this device (its reply may have been lost), and after a restart a
  /// fresh preview's manifest lists it.
  Future<ApplyResult> commitRestore(RestorePreview preview) =>
      _userOp(() async {
        if (_state != null) throw const BackupAlreadyOnException();
        final identity = await _loadIdentity();
        final signer =
            backupB64((await identity.signer.extractPublicKey()).bytes);
        final member = preview.manifest.members
            .any((m) => !m.recovery && backupB64(m.signer) == signer);
        final Rotation joined;
        if (member) {
          joined = (epoch: preview.epoch, vaultKey: preview.vaultKey);
        } else {
          final earlier = await _joinedEarlier(preview.vaultId, identity);
          if (earlier != null) {
            joined = earlier;
          } else {
            // From here until the state is saved the outcome is uncertain:
            // the relay may add this device and the reply still be lost.
            _restoreTried = preview.vaultId;
            joined = await _ops.addSelfWithRecovery(
              vaultId: preview.vaultId,
              recovery: preview.recovery,
              identity: identity,
              epoch: preview.epoch,
              vaultKey: preview.vaultKey,
            );
          }
        }
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
        await _meta.clearMergedSeqs();
        final result = await _apply(preview.payloads, BackupApplyMode.restore);
        for (final e in preview.slotSeqs.entries) {
          await _meta.setMergedSeq(e.key, e.value);
        }
        for (final e in preview.payloads.entries) {
          await _rememberName(e.key, e.value.deviceName);
        }
        try {
          await _save(state);
        } catch (_) {
          _state = null;
          _set(const BackupError(BackupRelayError.server, null));
          rethrow;
        }
        _restoreTried = null;
        _refreshOffers();
        await _publishMembers(preview.manifest, identity.slotId);
        await _join(state, identity);
        await _attempt(() => _upload(force: true));
        return result;
      });

  // Pending accounts

  /// Adds an account another device backed up. Polls first when its record
  /// is no longer in memory (after a restart).
  Future<void> acceptPendingAccount(String accountId) => _userOp(() async {
        try {
          if (!_accountRecords.containsKey(accountId) && _state != null) {
            await _pollOnce(full: true);
          }
          final record = _accountRecords[accountId];
          if (record == null) {
            throw StateError('account $accountId is not in the backup');
          }
          if (!await _snapshot.addAccount(record)) {
            throw StateError('account $accountId could not be added');
          }
        } finally {
          _refreshOffers();
        }
      });

  Future<void> dismissPendingAccount(String accountId) async {
    final offer = _meta.pendingAccount(accountId);
    if (offer != null) await _meta.dismiss(accountId, offer.updatedAt);
    _refreshOffers();
  }

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
  Future<void> acknowledgeNewRecoveryKey() => _serialise(() async {
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
    await _attempt(() => _upload(force: true));
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
      final identity = await _identityOnce();
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
  /// vault. A write that finishes after [deadline] is undone the same way
  /// (see [_dropLateMember]). Pairing goes on without it.
  ///
  /// A signer already in the vault is not recorded against [nodeId]: the
  /// joiner proved nothing about owning it, and a revocation must not
  /// reach another member's slot. That member's own group record says
  /// which node it is.
  Future<String?> addMemberForPair(String signerB64, String boxB64,
          {String? nodeId, DateTime? deadline}) =>
      _serialise(() async {
        bool late() => deadline != null && _clock().isAfter(deadline);
        if (!_active || late()) return null;
        try {
          final signerPub = backupUnb64(signerB64);
          final boxPub = backupUnb64(boxB64);
          if (signerPub.length != 32 || boxPub.length != 32) return null;
          final (_, identity) = _require();
          for (var attempt = 0;; attempt++) {
            final vaultId = _state!.vaultId;
            final m = (await _relay.manifest(vaultId, identity.signer))!;
            final state = await _adoptEpoch(m);
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
              if (e.kind == BackupRelayError.conflict && attempt == 0) {
                continue;
              }
              if (late()) await _dropLateMember(signerPub);
              rethrow;
            } catch (_) {
              if (late()) await _dropLateMember(signerPub);
              rethrow;
            }
            if (nodeId != null) {
              await _meta.setNodeToSlot(
                  nodeId, VaultCrypto.slotIdFor(signerPub));
            }
            // Checked after the last await: the host's timer fires no
            // earlier than [deadline], so a vault id returned now reaches
            // it. Past that, the host replied without one and the joiner
            // will never adopt the vault: undo the membership.
            if (late()) {
              if (nodeId != null) await _meta.removeNode(nodeId);
              await _dropLateMember(signerPub);
              return null;
            }
            if (nodeId != null) markDirty();
            return vaultId;
          }
        } catch (e) {
          debugPrint('[Backup] Paired device not added: ${e.runtimeType}');
          return null;
        }
      });

  /// Takes out a member [addMemberForPair] added, or may have added, after
  /// the host stopped waiting. The rotation keeps the recovery key: unlike a
  /// device removed later, the joiner never held it (pairing does not share
  /// it, and a device that restored with it is already listed, so never
  /// added here). Best effort: on failure the joiner stays a member that
  /// never uploads, which Backup & sync can remove.
  Future<void> _dropLateMember(List<int> signerPub) async {
    try {
      await _rotate(removeSlotId: VaultCrypto.slotIdFor(signerPub));
    } catch (e) {
      debugPrint('[Backup] Late pairing member not removed: ${e.runtimeType}');
    }
  }

  /// The joiner side of pairing: takes up [vaultId], which the host just
  /// added this device to, and raises [joinedNotice]. Uploading this
  /// device's slot and merging the group's is queued, not awaited, so
  /// pairing does not wait on a 4 MB transfer. A device already in another
  /// vault is not switched: [pendingVaultChoice] asks the viewer instead.
  Future<void> adoptVault(String vaultId) => _serialise(() async {
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
        unawaited(_background(_uploadAndMerge));
      });

  /// Completes once every operation queued so far has run.
  @visibleForTesting
  Future<void> settled() => _serialise(() async {});

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
      _serialise(() async {
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
        await _attempt(_uploadAndMerge);
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
    _cancelTimers();
    _failedSlots.clear();
    _accountRecords.clear();
    _setMismatch(false);
    _setMembers(const []);
    await _meta.clearMergedSeqs();
    await _meta.clearSlotClaims();
    await _meta.clearSlotNames();
    await _meta.clearOffers();
    await _meta.clearPendingRemovals();
    _refreshOffers();
    try {
      await _save(state);
    } catch (_) {
      _state = null;
      _set(const BackupError(BackupRelayError.server, null));
      rethrow;
    }
    await _join(state, identity);
  }

  Future<void> _uploadAndMerge() async {
    await _upload(force: true);
    await _pollOnce(full: true);
  }

  void _setChoice(VaultChoice? choice) {
    if (!_disposed) _vaultChoice.value = choice;
  }

  // Upload

  Future<void> _uploadIfDirty() async {
    if (_dirty) await _upload();
  }

  /// Seals this device's records into its slot. Skipped when the records
  /// are what was last uploaded, unless [force]d (a new epoch, a join).
  Future<void> _upload({bool force = false}) async {
    var (state, identity) = _require();
    _dirty = false;
    try {
      await _recordOwnNode(identity);
      final records = lwwMerge([await _snapshot.collect(nowMs: _nowMs)]);
      final hash = sha256
          .convert(
              utf8.encode(jsonEncode([for (final r in records) r.toJson()])))
          .toString();
      if (!force && hash == _uploadedHash) return;
      final plaintext = BackupPayload(
        deviceName: await _deviceName(),
        platform: _platform,
        createdAt: _nowMs,
        records: records,
      ).encode();
      for (var attempt = 0;; attempt++) {
        final seq = state.ownSeq + 1;
        final sealed = await VaultCrypto.sealSlot(
          vaultKey: state.keysByEpoch[state.epoch]!,
          vaultId: state.vaultId,
          epoch: state.epoch,
          slotId: identity.slotId,
          seq: seq,
          plaintext: plaintext,
        );
        if (sealed.length > maxSlotBytes) {
          throw const BackupRelayException(BackupRelayError.tooLarge);
        }
        _set(const BackupUploading());
        final int newSeq;
        try {
          newSeq = await _relay.putSlot(
              state.vaultId, identity.signer, identity.slotId, sealed,
              ifMatch: state.ownSeq == 0 ? null : state.ownSeq,
              epoch: state.epoch);
        } on BackupRelayException catch (e) {
          // 412: another seq is stored; 409: the epoch moved. Read the
          // manifest and write again once.
          if (attempt > 0 ||
              (e.kind != BackupRelayError.preconditionFailed &&
                  e.kind != BackupRelayError.conflict)) {
            rethrow;
          }
          final m = (await _relay.manifest(state.vaultId, identity.signer))!;
          state = await _adoptEpoch(m);
          final own =
              m.slots.where((s) => s.slotId == identity.slotId).firstOrNull;
          state = state.copyWith(ownSeq: own?.seq ?? 0);
          _state = state;
          continue;
        }
        state = state.copyWith(ownSeq: newSeq, lastSuccessMs: () => _nowMs);
        await _save(state);
        _uploadedHash = hash;
        _tooLarge = false;
        _setMembers([
          for (final m in _members.value)
            m.isThisDevice
                ? BackupMemberInfo(
                    slotId: m.slotId,
                    isThisDevice: true,
                    deviceName: m.deviceName,
                    lastUploadMs: state.lastSuccessMs,
                  )
                : m,
        ]);
        _set(BackupIdle(state.lastSuccessMs));
        return;
      }
    } catch (_) {
      _dirty = true;
      rethrow;
    }
  }

  // Poll

  /// Reads the manifest (with the stored ETag when [conditional] and not
  /// [full]), takes up a new epoch, and merges every slot whose seq is above
  /// what was merged (every slot when [full]) in live mode.
  Future<void> _pollOnce({bool full = false, bool conditional = true}) async {
    var (state, identity) = _require();
    final m = await _relay.manifest(state.vaultId, identity.signer,
        etag: full || !conditional ? null : state.manifestEtag);
    if (m == null) return _idle();
    state = await _reconcileRecovery(state, m);
    state = await _adoptEpoch(m);

    final own = m.slots.where((s) => s.slotId == identity.slotId).firstOrNull;
    if (own != null && own.seq > state.ownSeq) {
      state = state.copyWith(ownSeq: own.seq);
    }
    final payloads = <String, BackupPayload>{};
    final unreadable = <String>{};
    for (final s in m.slots) {
      if (s.slotId == identity.slotId) continue;
      if (!full && s.seq <= _meta.mergedSeq(s.slotId)) continue;
      if (_failedSlots[s.slotId] == s.seq) {
        unreadable.add(s.slotId);
        continue;
      }
      final p =
          await _readSlot(state.vaultId, identity.signer, s, state.keysByEpoch);
      if (p == null) {
        unreadable.add(s.slotId);
        _failedSlots[s.slotId] = s.seq;
      } else {
        payloads[s.slotId] = p;
        _failedSlots.remove(s.slotId);
      }
    }
    await _apply(payloads, BackupApplyMode.live);
    for (final s in m.slots) {
      if (payloads.containsKey(s.slotId)) {
        await _meta.setMergedSeq(s.slotId, s.seq);
      }
    }
    _refreshOffers();
    await _publishMembers(m, identity.slotId);
    if (!_disposed) _unreadable.value = unreadable;
    // An unreadable slot keeps the ETag unset, so the next poll reads the
    // manifest again (the slot itself only once its seq moves) and the
    // unreadable list stays current.
    final etag = unreadable.isEmpty ? m.etag : null;
    if (etag != state.manifestEtag || state.ownSeq != _state!.ownSeq) {
      state = state.copyWith(manifestEtag: () => etag);
      await _save(state);
    }
    _idle();
    // After a rotation every member re-uploads under the new key.
    if (own != null && own.epoch < m.epoch) await _upload(force: true);
  }

  Future<BackupPayload?> _readSlot(String vaultId, SimpleKeyPair signer,
      ManifestSlot slot, Map<int, Uint8List> keys) async {
    final payload = await _ops.readSlot(vaultId, signer, slot, keys);
    if (payload != null) await _rememberName(slot.slotId, payload.deviceName);
    return payload;
  }

  Future<void> _rememberName(String slotId, String name) async {
    if (_meta.slotNames()[slotId] != name) {
      await _meta.setSlotName(slotId, name);
    }
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

  void _refreshOffers() {
    if (!_disposed) _offers.value = _meta.pendingAccounts();
  }

  Future<ApplyResult> _apply(
      Map<String, BackupPayload> payloads, BackupApplyMode mode) async {
    for (final MapEntry(key: slotId, value: p) in payloads.entries) {
      // The newest version wins, whatever order the slots (or polls) come
      // in: an accepted offer gets the credentials the merge chose.
      for (final r in p.records.whereType<AccountBackupRecord>()) {
        if (r.deleted) continue;
        final held = _accountRecords[r.accountId];
        if (held == null ||
            identical(
                lwwMerge([
                  [held],
                  [r]
                ]).single,
                r)) {
          _accountRecords[r.accountId] = r;
        }
      }
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
    return applyByOrigin(_snapshot, payloads, mode: mode, nowMs: _nowMs);
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

  // Epochs and rotation

  /// Takes up [m]'s epoch when this device does not hold its key yet,
  /// opening its own envelope, and saves at once.
  Future<BackupVaultState> _adoptEpoch(BackupManifest m) async {
    final state = _state!;
    if (m.epoch == state.epoch && state.keysByEpoch.containsKey(m.epoch)) {
      return state;
    }
    final Uint8List key;
    try {
      key = await VaultCrypto.openEnvelope(
        box: _identity!.box,
        envelope: m.envelope,
        vaultId: state.vaultId,
        epoch: m.epoch,
      );
    } on VaultCryptoException {
      throw const BackupRelayException(BackupRelayError.invalid);
    }
    final next = state.copyWith(
      epoch: m.epoch,
      keysByEpoch: {...state.keysByEpoch, m.epoch: key},
      manifestEtag: () => null,
    );
    await _save(next);
    return next;
  }

  /// Rotates after taking up the epoch of every manifest the rotation reads
  /// (so slots still at it stay readable, even when a conflict moves it on),
  /// and saves the new key as soon as the relay accepted it.
  Future<Rotation?> _rotate(
      {String? removeSlotId, RecoveryMember? newRecovery}) async {
    final (state, identity) = _require();
    final rotation = await _ops.rotate(
      vaultId: state.vaultId,
      signer: identity.signer,
      removeSlotId: removeSlotId,
      newRecovery: newRecovery,
      onManifest: (m) => _adoptEpoch(m),
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

  /// The identity, loaded or created once. [pairKeys] runs outside the
  /// queue, so two first uses can overlap: they share one load, or each
  /// would read "absent" and create its own, and membership made with the
  /// one that lost the write could never authenticate again.
  Future<BackupIdentity> _identityOnce() {
    final known = _identity;
    if (known != null) return Future.value(known);
    return _identityLoad ??= BackupIdentity.loadOrCreate(_auth)
        .then((identity) => _identity = identity)
        .whenComplete(() => _identityLoad = null);
  }

  Future<BackupIdentity>? _identityLoad;

  Future<BackupIdentity> _loadIdentity() async {
    try {
      return await _identityOnce();
    } on StateError {
      _set(const BackupError(BackupRelayError.server, null));
      rethrow;
    }
  }

  /// Persists [state] and makes it current. A storage that cannot persist
  /// throws [StateError], which callers report as `Error(server)`.
  Future<void> _save(BackupVaultState state) async {
    _state = state;
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

  Future<void> _join(BackupVaultState state, BackupIdentity identity) async {
    _halted = false;
    _state = state;
    _identity = identity;
    _uploadedHash = null;
    _failures = 0;
    _set(BackupIdle(state.lastSuccessMs));
    _startPolling();
  }

  /// Clears `backup/vault` and the merged seqs; local data is kept.
  Future<void> _leave(BackupStatus next) async {
    _cancelTimers();
    _state = null;
    _dirty = false;
    _uploadedHash = null;
    _tooLarge = false;
    _failedSlots.clear();
    _setMismatch(false);
    _publishUnsavedKey();
    _accountRecords.clear();
    _setMembers(const []);
    _setChoice(null);
    if (!_disposed) _joinedNotice.value = false;
    await _store.clear();
    await _meta.clearMergedSeqs();
    await _meta.clearSlotClaims();
    await _meta.clearSlotNames();
    await _meta.clearOffers();
    await _meta.clearPendingRemovals();
    _refreshOffers();
    _publishRemovals();
    await _meta.setJoinedNoticePending(false);
    if (!_disposed) _unreadable.value = const {};
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

  Future<T> _serialise<T>(Future<T> Function() op) {
    final result = _queue.then((_) => op());
    _queue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  /// An operation the viewer asked for: errors are rethrown to the caller
  /// after the status reflects a removal or a missing relay feature.
  ///
  /// The viewer acting is a retry: an earlier [BackupUnavailable] is lifted
  /// for the op, and stays lifted when it succeeds. A vault that is gone
  /// means this device was removed only when the op addressed this
  /// device's own vault ([ownVault]), not, say, a preview of another one.
  Future<T> _userOp<T>(Future<T> Function() op, {bool ownVault = true}) =>
      _serialise(() async {
        final vaultId = _state?.vaultId;
        final wasHalted = _halted;
        _halted = false;
        try {
          final result = await op();
          if (wasHalted && !_halted) {
            if (_state != null && _pollTimer == null) _startPolling();
            if (_status.value is BackupUnavailable) {
              _state == null ? _set(const BackupOff()) : _idle();
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
            _halt();
          } else if (wasHalted) {
            _halted = true;
          }
          rethrow;
        } catch (_) {
          if (wasHalted) _halted = true;
          rethrow;
        }
      });

  /// A background operation, queued: errors become the status and a retry.
  Future<void> _background(Future<void> Function() op) =>
      _serialise(() => _attempt(op));

  /// Runs [op] in the current queue slot, reporting failure as status.
  Future<void> _attempt(Future<void> Function() op) async {
    if (!_active) return;
    try {
      await op();
      // A poll can succeed while an upload still waits for its retry: the
      // debounce has already fired, so the retry is what sends it.
      if (!_dirty) {
        _failures = 0;
        _retryTimer?.cancel();
        _retryTimer = null;
      }
      if (_status.value is BackupError) _idle();
    } on BackupRelayException catch (e) {
      await _failed(e.kind, e);
    } on Object catch (e) {
      // Malformed 2xx bodies and storage failures are server-side errors.
      debugPrint('[Backup] Sync failed: ${e.runtimeType}');
      await _failed(BackupRelayError.server, null);
    }
  }

  Future<void> _failed(BackupRelayError kind, BackupRelayException? e) async {
    if (_disposed) return;
    if (e != null && _gone(e)) return _leave(const BackupRemoved());
    if (kind == BackupRelayError.unavailable) return _halt();
    _set(BackupError(kind, _state?.lastSuccessMs));
    // An oversize slot fails the same way until the data shrinks: the next
    // change tries again, not a timer.
    if (kind == BackupRelayError.tooLarge) {
      _tooLarge = true;
      return;
    }
    _failures++;
    var delay = Duration(minutes: 1 << min(_failures - 1, 5));
    if (delay > maxBackoff) delay = maxBackoff;
    final retryAfter = e?.retryAfterMs;
    if (retryAfter != null && retryAfter > delay.inMilliseconds) {
      delay = Duration(milliseconds: retryAfter);
    }
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_background(() async {
        await _pollOnce();
        await _uploadIfDirty();
      }));
    });
  }

  void _halt() {
    _halted = true;
    _cancelTimers();
    _set(const BackupUnavailable());
  }

  void _idle() {
    if (_tooLarge) return;
    _set(BackupIdle(_state?.lastSuccessMs));
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(poll()));
  }

  void _cancelTimers() {
    _debounceTimer?.cancel();
    _pollTimer?.cancel();
    _retryTimer?.cancel();
    _debounceTimer = _pollTimer = _retryTimer = null;
  }

  void _set(BackupStatus s) {
    if (!_disposed) _status.value = s;
  }
}
