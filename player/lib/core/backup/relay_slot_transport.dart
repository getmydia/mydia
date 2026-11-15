import 'dart:async';
import 'dart:typed_data';

import 'backup_identity.dart';
import 'backup_records.dart';
import 'backup_relay_client.dart';
import 'backup_vault_ops.dart';
import 'backup_vault_state.dart';
import 'slot_transport.dart';
import 'vault_crypto.dart';

/// The relay vault as a [SlotTransport]: seals and opens slots under the
/// vault key, compare-and-swaps each write on the slot's seq and the vault
/// epoch, and takes up a new epoch whenever a manifest shows one. Owns the
/// vault state it changes ([state]) and saves it after every change.
///
/// Not safe for concurrent calls: the caller runs one at a time, so the
/// state is never read and written by two at once.
class RelaySlotTransport implements SlotTransport {
  RelaySlotTransport({
    required BackupRelayClient relay,
    required BackupVaultStateStore store,
    required BackupIdentity identity,
    required BackupVaultState state,
    required int Function() nowMs,
  })  : _relay = relay,
        _ops = BackupVaultOps(relay),
        _store = store,
        _identity = identity,
        _state = state,
        _nowMs = nowMs;

  /// The relay's slot size cap; a larger sealed slot is never sent.
  static const maxSlotBytes = 4194304;

  final BackupRelayClient _relay;
  final BackupVaultOps _ops;
  final BackupVaultStateStore _store;
  final BackupIdentity _identity;
  final int Function() _nowMs;
  BackupVaultState _state;
  BackupManifest? _lastManifest;
  final _manifests = StreamController<BackupManifest>.broadcast(sync: true);

  /// Device names seen in this session: the manifest carries none, so a
  /// slot is named once it was read (or, for this device, written).
  final _names = <String, String>{};

  /// Runs on every manifest [list] reads, before its epoch is taken up; the
  /// state it returns becomes current. The service settles a recovery key
  /// replacement here.
  Future<BackupVaultState> Function(BackupManifest)? beforeAdopt;

  /// Current, saved after every change.
  BackupVaultState get state => _state;

  /// From the last [list] that returned a listing.
  BackupManifest? get lastManifest => _lastManifest;

  /// Every manifest read, before its epoch is taken up.
  Stream<BackupManifest> get manifests => _manifests.stream;

  @override
  String get ownSlotId => _identity.slotId;

  /// The relay has no push; the caller polls.
  @override
  Stream<void> get changes => const Stream.empty();

  /// [cursor] is the manifest ETag. Takes up the manifest's epoch and
  /// catches the own seq up to what the relay stores.
  @override
  Future<SlotListing?> list({String? cursor}) async {
    final m =
        await _relay.manifest(_state.vaultId, _identity.signer, etag: cursor);
    if (m == null) return null;
    _manifests.add(m);
    final hook = beforeAdopt;
    if (hook != null) {
      final next = await hook(m);
      if (!identical(next, _state)) await _save(next);
    }
    await _adoptEpoch(m);
    final own = m.slots.where((s) => s.slotId == ownSlotId).firstOrNull;
    if (own != null && own.seq > _state.ownSeq) {
      await _save(_state.copyWith(ownSeq: own.seq));
    }
    _lastManifest = m;
    return SlotListing(
      cursor: m.etag,
      slots: [
        for (final s in m.slots)
          SlotInfo(
            slotId: s.slotId,
            version: '${s.seq}',
            deviceName: _names[s.slotId],
            updatedAtMs: s.updatedAt,
            size: s.size,
          ),
      ],
      // After a rotation every member re-uploads under the new key.
      ownStale: own != null && own.epoch < m.epoch,
    );
  }

  /// [slot] must come from the last listing.
  @override
  Future<BackupPayload> read(SlotInfo slot) async {
    final s = _lastManifest?.slots
        .where((x) => x.slotId == slot.slotId && '${x.seq}' == slot.version)
        .firstOrNull;
    if (s == null) {
      throw StateError('slot ${slot.slotId} is not in the last listing');
    }
    final payload = await _ops.readSlot(
        _state.vaultId, _identity.signer, s, _state.keysByEpoch);
    if (payload == null) {
      throw FormatException('slot ${slot.slotId} is unreadable');
    }
    _names[slot.slotId] = payload.deviceName;
    return payload;
  }

  /// Seals [payload] at the next seq and writes it. On a 412 (another seq is
  /// stored) or a 409 (the epoch moved) reads the manifest, takes up its
  /// epoch and seq, and writes again once.
  @override
  Future<void> writeOwn(BackupPayload payload) async {
    final plaintext = payload.encode();
    var state = _state;
    for (var attempt = 0;; attempt++) {
      final seq = state.ownSeq + 1;
      final sealed = await VaultCrypto.sealSlot(
        vaultKey: state.keysByEpoch[state.epoch]!,
        vaultId: state.vaultId,
        epoch: state.epoch,
        slotId: ownSlotId,
        seq: seq,
        plaintext: plaintext,
      );
      if (sealed.length > maxSlotBytes) {
        throw const BackupRelayException(BackupRelayError.tooLarge);
      }
      final int newSeq;
      try {
        newSeq = await _relay.putSlot(
            state.vaultId, _identity.signer, ownSlotId, sealed,
            ifMatch: state.ownSeq == 0 ? null : state.ownSeq,
            epoch: state.epoch);
      } on BackupRelayException catch (e) {
        if (attempt > 0 ||
            (e.kind != BackupRelayError.preconditionFailed &&
                e.kind != BackupRelayError.conflict)) {
          rethrow;
        }
        final m = (await _relay.manifest(state.vaultId, _identity.signer))!;
        _manifests.add(m);
        state = await _adoptEpoch(m);
        final own = m.slots.where((s) => s.slotId == ownSlotId).firstOrNull;
        state = state.copyWith(ownSeq: own?.seq ?? 0);
        _state = state;
        continue;
      }
      await _save(
          state.copyWith(ownSeq: newSeq, lastSuccessMs: () => _nowMs()));
      _names[ownSlotId] = payload.deviceName;
      return;
    }
  }

  /// The relay removes a slot only with its member, in a key rotation
  /// (`BackupVaultOps.rotate`), never on its own.
  @override
  Future<void> delete(String slotId) async =>
      throw UnsupportedError('the relay deletes a slot only with its member');

  /// Takes up [m]'s epoch when this device does not hold its key yet,
  /// opening its own envelope, and saves at once.
  Future<BackupVaultState> _adoptEpoch(BackupManifest m) async {
    final state = _state;
    if (m.epoch == state.epoch && state.keysByEpoch.containsKey(m.epoch)) {
      return state;
    }
    final Uint8List key;
    try {
      key = await VaultCrypto.openEnvelope(
        box: _identity.box,
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

  /// Makes [state] current and persists it. A storage that cannot persist
  /// throws [StateError].
  Future<void> _save(BackupVaultState state) async {
    _state = state;
    await _store.save(state);
  }
}
