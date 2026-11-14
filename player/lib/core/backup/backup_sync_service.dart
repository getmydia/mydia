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
  })  : _relay = relay,
        _ops = BackupVaultOps(relay),
        _auth = authStorage,
        _store = BackupVaultStateStore(authStorage),
        _meta = meta,
        _snapshot = snapshot,
        _deviceName = deviceName,
        _platform = platform,
        _clock = clock ?? DateTime.now;

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

  final _status = ValueNotifier<BackupStatus>(const BackupOff());
  final _unreadable = ValueNotifier<Set<String>>(const {});

  ValueListenable<BackupStatus> get status => _status;

  /// Slot ids whose last download could not be opened or decoded.
  ValueListenable<Set<String>> get unreadableSlots => _unreadable;

  /// Device names from the slots read so far, by slot id.
  Map<String, String> get slotDeviceNames => Map.unmodifiable(_slotNames);
  final _slotNames = <String, String>{};

  BackupVaultState? _state;
  BackupIdentity? _identity;
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
  Future<void> start() async {
    _halted = false;
    try {
      _state = await _store.load();
      if (_state == null) return _set(const BackupOff());
      _identity = await BackupIdentity.loadOrCreate(_auth);
    } catch (e) {
      debugPrint('[Backup] Could not load the backup state: $e');
      return _set(BackupError(BackupRelayError.server, _state?.lastSuccessMs));
    }
    _set(BackupIdle(_state!.lastSuccessMs));
    _startPolling();
    // A change made just before the app was killed may never have gone up.
    markDirty();
    unawaited(poll());
  }

  void dispose() {
    _disposed = true;
    _cancelTimers();
    _status.dispose();
    _unreadable.dispose();
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
        await _attempt(() => _upload(force: true));
      });

  /// Finds [keyText]'s vault and reads every slot, as its recovery member.
  /// Changes nothing on the device or the relay.
  Future<RestorePreview> previewRestore(String keyText) => _userOp(() async {
        final recovery = await RecoveryMember.of(RecoveryKey.parse(keyText));
        return _ops.preview(recovery);
      });

  /// Joins [preview]'s vault (added by the recovery member, no rotation),
  /// applies its records in restore mode, and uploads this device's slot.
  Future<ApplyResult> commitRestore(RestorePreview preview) =>
      _userOp(() async {
        if (_state != null) throw StateError('backup is already on');
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
          _state = null;
          _set(const BackupError(BackupRelayError.server, null));
          rethrow;
        }
        await _meta.clearMergedSeqs();
        final result = await _apply(preview.payloads, BackupApplyMode.restore);
        for (final e in preview.slotSeqs.entries) {
          await _meta.setMergedSeq(e.key, e.value);
        }
        for (final e in preview.payloads.entries) {
          _slotNames[e.key] = e.value.deviceName;
        }
        await _join(state, identity);
        await _attempt(() => _upload(force: true));
        return result;
      });

  // Pending accounts

  /// Adds an account another device backed up. Polls first when its record
  /// is no longer in memory (after a restart).
  Future<void> acceptPendingAccount(String accountId) => _userOp(() async {
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
      });

  Future<void> dismissPendingAccount(String accountId) async {
    final offer = _meta.pendingAccount(accountId);
    if (offer != null) await _meta.dismiss(accountId, offer.updatedAt);
  }

  // Member changes

  /// Removes the member owning [slotId] and rotates to a fresh vault key
  /// sealed to every remaining member and the recovery member.
  Future<void> removeMember(String slotId) => _userOp(() async {
        final rotation = await _rotate(removeSlotId: slotId);
        if (rotation != null) await _attempt(() => _upload(force: true));
      });

  /// Replaces the recovery key (and rotates). The old key stops working.
  Future<RecoveryKey> regenerateRecoveryKey() => _userOp(() async {
        final key = RecoveryKey.generate();
        await _rotate(newRecovery: await RecoveryMember.of(key));
        await _attempt(() => _upload(force: true));
        return key;
      });

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
        await _ignoreGone(() async {
          final m = (await _relay.manifest(state.vaultId, identity.signer))!;
          final others = m.members
              .where((x) => !x.recovery && x.slotId != identity.slotId);
          if (others.isEmpty) {
            await _relay.deleteVault(state.vaultId, identity.signer);
          } else {
            await _ops.rotate(
                vaultId: state.vaultId,
                signer: identity.signer,
                removeSlotId: identity.slotId);
          }
        });
        await _leave(const BackupOff());
      });

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
        _set(BackupIdle(state.lastSuccessMs));
        return;
      }
    } catch (_) {
      _dirty = true;
      rethrow;
    }
  }

  // Poll

  /// Reads the manifest (conditionally unless [full]), takes up a new
  /// epoch, and merges every slot whose seq is above what was merged (every
  /// slot when [full]) in live mode.
  Future<void> _pollOnce({bool full = false}) async {
    var (state, identity) = _require();
    final m = await _relay.manifest(state.vaultId, identity.signer,
        etag: full ? null : state.manifestEtag);
    if (m == null) return _idle();
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
      final p =
          await _readSlot(state.vaultId, identity.signer, s, state.keysByEpoch);
      if (p == null) {
        unreadable.add(s.slotId);
      } else {
        payloads[s.slotId] = p;
      }
    }
    await _apply(payloads, BackupApplyMode.live);
    for (final s in m.slots) {
      if (payloads.containsKey(s.slotId)) {
        await _meta.setMergedSeq(s.slotId, s.seq);
      }
    }
    if (!_disposed) _unreadable.value = unreadable;
    // An unreadable slot keeps the ETag unset, so the next poll tries it
    // again rather than getting a 304.
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
    if (payload != null) _slotNames[slot.slotId] = payload.deviceName;
    return payload;
  }

  Future<ApplyResult> _apply(
      Map<String, BackupPayload> payloads, BackupApplyMode mode) async {
    for (final p in payloads.values) {
      for (final r in p.records.whereType<AccountBackupRecord>()) {
        if (!r.deleted) _accountRecords[r.accountId] = r;
      }
    }
    return applyByOrigin(_snapshot, payloads, mode: mode, nowMs: _nowMs);
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

  /// Rotates after taking up the current epoch (so slots still at it stay
  /// readable), and saves the new key as soon as the relay accepted it.
  Future<Rotation?> _rotate(
      {String? removeSlotId, RecoveryMember? newRecovery}) async {
    var (state, identity) = _require();
    final m = (await _relay.manifest(state.vaultId, identity.signer))!;
    state = await _adoptEpoch(m);
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
      manifestEtag: () => null,
    ));
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

  Future<BackupIdentity> _loadIdentity() async {
    try {
      return _identity ??= await BackupIdentity.loadOrCreate(_auth);
    } on StateError {
      _set(const BackupError(BackupRelayError.server, null));
      rethrow;
    }
  }

  /// Persists [state] and makes it current. A storage that cannot persist
  /// throws [StateError], which callers report as `Error(server)`.
  Future<void> _save(BackupVaultState state) async {
    _state = state;
    await _store.save(state);
  }

  Future<void> _join(BackupVaultState state, BackupIdentity identity) async {
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
    _accountRecords.clear();
    _slotNames.clear();
    await _store.clear();
    await _meta.clearMergedSeqs();
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
  Future<T> _userOp<T>(Future<T> Function() op) => _serialise(() async {
        try {
          return await op();
        } on BackupRelayException catch (e) {
          if (_gone(e) && _state != null) {
            await _leave(const BackupRemoved());
          } else if (e.kind == BackupRelayError.unavailable) {
            _halt();
          }
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
      _failures = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
      if (_status.value is BackupError) _idle();
    } on BackupRelayException catch (e) {
      await _failed(e.kind, e);
    } on Object catch (e) {
      // Malformed 2xx bodies and storage failures are server-side errors.
      debugPrint('[Backup] Sync failed: $e');
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
