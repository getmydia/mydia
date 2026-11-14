import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:flutter/foundation.dart' show debugPrint;

import 'backup_identity.dart';
import 'backup_records.dart';
import 'backup_status.dart';
import 'backup_relay_client.dart';
import 'recovery_key.dart';
import 'vault_crypto.dart';

/// 32 random bytes from a secure source.
Uint8List randomVaultKey() => _random(32);

/// A fresh vault id: 16 random bytes as lowercase hex.
String randomVaultId() => _hex(_random(16));

Uint8List _random(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

String _hex(List<int> bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

/// What a recovery key stands for on the relay.
class RecoveryMember {
  RecoveryMember._(this.key, this.signer, this.box, this.signerPub, this.boxPub,
      this.lookupHandle);

  static Future<RecoveryMember> of(RecoveryKey key) async {
    final signer = await key.signer();
    final box = await key.boxKey();
    return RecoveryMember._(
      key,
      signer,
      box,
      Uint8List.fromList((await signer.extractPublicKey()).bytes),
      Uint8List.fromList((await box.extractPublicKey()).bytes),
      await key.lookupHandle(),
    );
  }

  final RecoveryKey key;
  final SimpleKeyPair signer;
  final SimpleKeyPair box;
  final Uint8List signerPub;
  final Uint8List boxPub;
  final Uint8List lookupHandle;

  String get slotId => VaultCrypto.slotIdFor(signerPub);

  /// Lowercase hex SHA-256 of the lookup handle, what the relay stores.
  Future<String> lookupHash() async =>
      _hex((await Sha256().hash(lookupHandle)).bytes);
}

/// The result of a rotation: the epoch now on the relay and its key.
typedef Rotation = ({int epoch, Uint8List vaultKey});

/// The relay call sequences of the backup that are not the upload and poll
/// loop: creating a vault, joining one with a recovery key, and rotating
/// the vault key. Free of state: [BackupSyncService] owns what they return.
class BackupVaultOps {
  BackupVaultOps(this._relay);

  final BackupRelayClient _relay;

  static Future<Uint8List> seal(
    List<int> vaultKey,
    List<int> boxPub,
    String vaultId,
    int epoch,
  ) =>
      VaultCrypto.sealEnvelope(
        vaultKey: vaultKey,
        recipientBox: SimplePublicKey(boxPub, type: KeyPairType.x25519),
        vaultId: vaultId,
        epoch: epoch,
      );

  /// Creates a vault at epoch 1 holding [identity] and [recovery], under a
  /// vault id chosen here so both envelopes bind it. A taken id (a
  /// `conflict`) is retried once with a new one. Returns the vault id.
  Future<String> createVault(
    BackupIdentity identity,
    RecoveryMember recovery,
    Uint8List vaultKey,
  ) async {
    final signerPub = (await identity.signer.extractPublicKey()).bytes;
    final boxPub = (await identity.box.extractPublicKey()).bytes;
    for (var attempt = 0;; attempt++) {
      final vaultId = randomVaultId();
      try {
        final created = await _relay.createVault(CreateVaultRequest(
          vaultId: vaultId,
          signer: signerPub,
          boxPub: boxPub,
          slotId: identity.slotId,
          envelope: await seal(vaultKey, boxPub, vaultId, 1),
          recoverySigner: recovery.signerPub,
          recoveryBoxPub: recovery.boxPub,
          recoverySlotId: recovery.slotId,
          recoveryEnvelope: await seal(vaultKey, recovery.boxPub, vaultId, 1),
          lookupHash: await recovery.lookupHash(),
        ));
        // The envelopes bind the id sent; any other would not open.
        if (created != vaultId) {
          throw const BackupRelayException(BackupRelayError.invalid);
        }
        return created;
      } on BackupRelayException catch (e) {
        if (e.kind != BackupRelayError.conflict || attempt > 0) rethrow;
      }
    }
  }

  /// Finds the vault [recovery] opens and reads its manifest as the
  /// recovery member. Returns the vault key of the manifest's epoch.
  Future<({String vaultId, BackupManifest manifest, Uint8List vaultKey})>
      openWithRecovery(RecoveryMember recovery) async {
    final vaultId = await _relay.lookup(recovery.lookupHandle);
    final manifest = (await _relay.manifest(vaultId, recovery.signer))!;
    final vaultKey = await VaultCrypto.openEnvelope(
      box: recovery.box,
      envelope: manifest.envelope,
      vaultId: vaultId,
      epoch: manifest.epoch,
    );
    return (vaultId: vaultId, manifest: manifest, vaultKey: vaultKey);
  }

  /// Reads [recovery]'s vault and every slot in it, as the recovery
  /// member. Writes nothing. A slot at an older epoch than the recovery
  /// envelope's (not yet re-uploaded since a rotation) is unreadable here.
  Future<RestorePreview> preview(RecoveryMember recovery) async {
    final opened = await openWithRecovery(recovery);
    final payloads = <String, BackupPayload>{};
    final seqs = <String, int>{};
    final unreadable = <String>{};
    for (final s in opened.manifest.slots) {
      final p = await readSlot(opened.vaultId, recovery.signer, s,
          {opened.manifest.epoch: opened.vaultKey});
      if (p == null) {
        unreadable.add(s.slotId);
      } else {
        payloads[s.slotId] = p;
        seqs[s.slotId] = s.seq;
      }
    }
    return RestorePreview(
      vaultId: opened.vaultId,
      recovery: recovery,
      manifest: opened.manifest,
      vaultKey: opened.vaultKey,
      payloads: payloads,
      slotSeqs: seqs,
      unreadableSlots: unreadable,
    );
  }

  /// Adds [identity] to [vaultId] as the recovery member, without rotation:
  /// one envelope, for the device itself. On a `conflict` (the epoch moved
  /// since [epoch]) the manifest and the recovery envelope are read again
  /// and the add retried once. Returns the epoch and its key.
  Future<Rotation> addSelfWithRecovery({
    required String vaultId,
    required RecoveryMember recovery,
    required BackupIdentity identity,
    required int epoch,
    required Uint8List vaultKey,
  }) async {
    final signerPub = (await identity.signer.extractPublicKey()).bytes;
    final boxPub = (await identity.box.extractPublicKey()).bytes;
    var current = (epoch: epoch, vaultKey: vaultKey);
    for (var attempt = 0;; attempt++) {
      try {
        await _relay.updateMembers(
          vaultId,
          recovery.signer,
          MemberUpdate(
            expectedEpoch: current.epoch,
            newEpoch: current.epoch,
            add: [
              MemberAdd(
                  signer: signerPub, boxPub: boxPub, slotId: identity.slotId),
            ],
            envelopes: {
              backupB64(signerPub):
                  await seal(current.vaultKey, boxPub, vaultId, current.epoch),
            },
          ),
        );
        return current;
      } on BackupRelayException catch (e) {
        if (e.kind != BackupRelayError.conflict || attempt > 0) rethrow;
        final m = (await _relay.manifest(vaultId, recovery.signer))!;
        current = (
          epoch: m.epoch,
          vaultKey: await VaultCrypto.openEnvelope(
            box: recovery.box,
            envelope: m.envelope,
            vaultId: vaultId,
            epoch: m.epoch,
          ),
        );
      }
    }
  }

  /// Rotates [vaultId] to a fresh vault key at the manifest epoch plus one,
  /// signed by [signer]: removes the non-recovery member owning
  /// [removeSlotId] (with its slot) and/or replaces the recovery member with
  /// [newRecovery], and seals the new key to every remaining member and the
  /// recovery member. On a `conflict` the manifest is read again and the
  /// rotation retried once. Returns null when [removeSlotId] is no longer a
  /// member and nothing else was asked.
  Future<Rotation?> rotate({
    required String vaultId,
    required SimpleKeyPair signer,
    String? removeSlotId,
    RecoveryMember? newRecovery,
  }) async {
    for (var attempt = 0;; attempt++) {
      final manifest = (await _relay.manifest(vaultId, signer))!;
      final removed = removeSlotId == null
          ? null
          : manifest.members
              .where((m) => !m.recovery && m.slotId == removeSlotId)
              .firstOrNull;
      if (removed == null && newRecovery == null) return null;

      final epoch = manifest.epoch + 1;
      final vaultKey = randomVaultKey();
      final envelopes = <String, List<int>>{};
      for (final m in manifest.members) {
        if (identical(m, removed)) continue;
        if (m.recovery && newRecovery != null) continue;
        envelopes[backupB64(m.signer)] =
            await seal(vaultKey, m.boxPub, vaultId, epoch);
      }
      final recovery = newRecovery == null
          ? null
          : RecoveryReplacement(
              signer: newRecovery.signerPub,
              boxPub: newRecovery.boxPub,
              slotId: newRecovery.slotId,
              envelope:
                  await seal(vaultKey, newRecovery.boxPub, vaultId, epoch),
              lookupHash: await newRecovery.lookupHash(),
            );
      try {
        await _relay.updateMembers(
          vaultId,
          signer,
          MemberUpdate(
            expectedEpoch: manifest.epoch,
            newEpoch: epoch,
            remove: [if (removed != null) removed.signer],
            envelopes: envelopes,
            recovery: recovery,
          ),
        );
        return (epoch: epoch, vaultKey: vaultKey);
      } on BackupRelayException catch (e) {
        if (e.kind != BackupRelayError.conflict || attempt > 0) rethrow;
      }
    }
  }

  /// Downloads and opens [slot], or returns null when it cannot be read.
  Future<BackupPayload?> readSlot(
    String vaultId,
    SimpleKeyPair signer,
    ManifestSlot slot,
    Map<int, Uint8List> keys,
  ) async {
    final key = keys[slot.epoch];
    if (key == null) {
      debugPrint('[Backup] No key for slot ${slot.slotId} at ${slot.epoch}');
      return null;
    }
    final Uint8List sealed;
    try {
      sealed = await _relay.getSlot(vaultId, signer, slot.slotId);
    } on BackupRelayException catch (e) {
      // Removed between the manifest and this read.
      if (e.kind == BackupRelayError.notFound) return null;
      rethrow;
    }
    try {
      return BackupPayload.decode(await VaultCrypto.openSlot(
        vaultKey: key,
        vaultId: vaultId,
        epoch: slot.epoch,
        slotId: slot.slotId,
        seq: slot.seq,
        sealed: sealed,
      ));
    } on Object catch (e) {
      debugPrint('[Backup] Slot ${slot.slotId} unreadable: ${e.runtimeType}');
      return null;
    }
  }
}
