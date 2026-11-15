# Cloud backup (player)

End-to-end encrypted backup of the player's watch state, pins, servers and
settings, stored on the metadata relay. The relay holds
ciphertext and public keys only. Design:
`design/specs/2026-11-14-player-cloud-backup-design.md`. Wire format and relay
rules: `metadata-relay/docs/backup.md`, which the client here is built
against. Native only: nothing in this directory runs on web (`kIsWeb`), and
the Backup & sync section is hidden there (`isWebProvider`).

## Threat model

The relay never sees a vault key or plaintext, but it is trusted not to
forge membership: members take the member list from its manifest, and a
rotation seals the vault key to every box key listed. A
relay that inserted a member row of its own would receive the key at the
next rotation and read what is written under it from then on, though
nothing sealed before. Detecting that is out of scope; see "Threat model" in
the spec.

## Units

| File | Job |
| --- | --- |
| `backup_identity.dart` | This install's Ed25519 signer and X25519 box key, created on first use. The slot id is the first 16 hex chars of `SHA-256(signer public key)` |
| `recovery_key.dart` | 32 random bytes as 52 Crockford base32 chars in 13 groups of 4. HKDF derives the recovery signer, the recovery box key and the lookup handle |
| `vault_crypto.dart` | Seals and opens slots and envelopes. Pure, no I/O. Fixed vectors in its tests pin every derivation |
| `backup_relay_client.dart` | Signed `/backup/v1` calls and the error kinds (`BackupRelayError`) |
| `backup_vault_ops.dart` | Multi-call relay sequences: create, preview a restore, add, rotate |
| `backup_snapshot.dart` | Collects this device's records and applies other devices' records |
| `backup_sync_service.dart` | Debounced upload, polling, merge, member changes, pending offers. Free of Riverpod |
| `backup_providers.dart` | Wires the stores, the change triggers and the pairing hooks |

## Where state lives

- `AuthStorage` `backup/identity`: the device signer and box key. Never
  backed up, never leaves the install. Read with `StrictAuthRead` where the
  storage offers it, so a keyring that fails to answer is an error, never
  "absent" (which would generate a new identity over the old one). The
  service loads it once even when pairing and a user action ask together.
- `AuthStorage` `backup/vault`: vault id, epoch, the vault key per known
  epoch, this device's slot seq, the last success, and the recovery key text
  when this device holds it.
- Hive box `backup_meta` (`BackupMetaStore`): record stamps, pending account
  offers and dismissals, accounts added from the backup whose folder roots
  have not landed yet, the seq of each slot already merged, each slot's
  device name, the p2p node to slot map and each slot's node claims, revoked
  devices still to be removed from the vault, and whether the
  joined-by-pairing notice is still to be seen. Not backed up.

## Record kinds

Every record is last-writer-wins on its origin `updatedAt`, with tombstones.

| Kind | On a live device in the vault | On restore |
| --- | --- | --- |
| Watch | Merged | Merged |
| Pin | Merged | Merged |
| Account (record plus every secret under `source/<id>/`) | Offered: "2 sources added on Living Room TV", Add or Dismiss | Applied |
| Setting (only the keys in `kBackupSettingKeys`) | Ignored | Applied |
| Group (p2p group secret, node to slot claims) | Already shared by pairing | Only the node claims are taken. The secret is not applied: without the roster the device would think it is in a group whose members reject it |

Restore brings back sources, watch state, pins and settings and joins the
vault. It does not rejoin the p2p group: to sync with the other devices
directly again, pair once more.

Mydia accounts travel without tokens and come back flagged `needsReauth`.
Server locks, the Files index, downloads, caches, the iroh node key and the
backup identity are never backed up. A new setting is excluded until it is
added to the allowlist.

## Timing

An upload follows a change to a backed-up record (a watch or pin write, a
source account change, or a backed-up setting written through any
`SettingsService` or `SubtitleLanguagePrefs`, see `watchBackedUpSettings`),
at most once per 2 minutes,
and is forced when the app goes to the background. The manifest is polled on
foreground, after every p2p sync and every 15 minutes; only slots whose seq
moved are downloaded. Failures back off exponentially to 30 minutes.

## The recovery key and paired devices

The key can be shown only on a device that holds it: the one that created or
last regenerated it, or one restored with it. Pairing never sends it, because
a device holding it could rejoin the vault after being removed. A device that
joined by pairing therefore has `recoveryKeyText == null`; the UI hides "Show
recovery key" there and offers "Generate a new recovery key". When the key a
device keeps is no longer the vault's (`recoveryKeyMismatch`), the UI warns
and offers a new one.

Turning backup on shows the key and requires one randomly chosen group typed
back before `confirmEnable`. If `confirmEnable` fails, the UI asks
`prepareEnable` for a new key: the relay may have created the vault with the
old one, and its lookup handle is then taken.

## Pairing hook

`backupPairingHooksProvider` hands `PeerSyncService` four best-effort hooks:
the joiner sends its backup public keys with `Pair`; the host adds it to the
vault (`addMemberForPair`, at the current epoch, no rotation) and returns the
vault id; the joiner adopts it (`adoptVault`) and raises the one-time notice
"This device is now backed up with your group". A joiner already in another
vault is not switched: `pendingVaultChoice` asks which to keep. A hook that
fails or times out never fails pairing.

## Removing a device

`removeMember` removes a device and replaces the recovery key in one
rotation: the removed device may hold the old key (it created the vault, last
regenerated the key or restored with it), and the recovery member could
otherwise still read the manifest and open the next epoch's envelope. The new
key is stored as pending before the relay call, like `regenerateRecoveryKey`,
and the UI shows it until the viewer presses Done.

A replaced key is unsaved until that Done (`acknowledgeNewRecoveryKey`):
`backup/vault` carries `recoveryKeyUnacknowledged`, set when the rotation
lands or when `_reconcileRecovery` promotes a pending key whose reply was
lost or whose app died before the sheet came up. While it is set,
`unsavedRecoveryKey` is true and Backup & sync shows "Your recovery key was
replaced. Save the new one." with Show, which opens the same sheet. Leaving
or switching vaults drops it with the rest of the vault state.

Revoking a paired device writes nothing to the relay, since a removal needs
the viewer to save a new key. `notePeerRevoked` records a pending removal in
`backup_meta`, keyed by node id, with the slot the trusted node to slot rules
resolve (this device's own pairing record, or the slot's own group record
claiming the node; none when no slot or two slots claim it, until a record
settles it). `pendingRemovals` lists those whose slot is still a member, and
Backup & sync shows "{device} was removed from your devices but can still read
your backup" with Remove. An entry clears once its slot leaves the manifest,
and all of them when this device leaves or switches vaults.

## Failure behaviour

| Condition | Behaviour |
| --- | --- |
| Relay unreachable, 5xx, 429 | Backoff to 30 minutes; the status keeps the last success |
| 404 on `/backup/v1` (relay without the routes) | `BackupUnavailable`, "Cloud backup isn't available yet"; no retries until the next start or a user action |
| A slot fails to open | Skipped, the rest merge; "Couldn't read Living Room TV's backup" |
| 409 on rotation, or an unknown epoch | Refetch the manifest and envelope, retry once. Every manifest a rotation reads has its epoch's key kept, so a slot still at the epoch it lost to stays readable |
| A restore fails while applying records | The vault state is saved only after the apply, so backup stays off and the restore screen offers Restore again; the relay membership already made is reused |
| An account's folder roots fail to land | The account stays marked unfinished in `backup_meta`: it is not uploaded, and the next apply (restore or poll) adds it again |
| An upload fails, then a poll succeeds | The upload's retry stays scheduled while records are dirty |
| A pairing add finishes after the host's 10 s timeout | The host has replied without a vault id, so it rotates the joiner back out (keeping the recovery key, which the joiner never held) |
| 412 on upload | Refetch the manifest, upload again at the current seq |
| 403 `not_member`, vault gone | `BackupRemoved`: `backup/vault` is cleared, local data kept |
| 403 with no JSON `error` code (a WAF or bot-check page) | `BackupRelayError.server`: backoff and retry, never a removal |
| 403 `not_owner` | `BackupRelayError.notOwner`: a status error and a retry, never a removal |
| Restore while backup is on | `BackupAlreadyOnException`; the restore screen says to turn backup off first |
| Lookup 404 on restore | "No backup matches this key" |
| 413 slot too large | Status error; no partial upload |

The relay deletes a vault with no write for 180 days; the Backup & sync
section says so.

## UI

- Backup & sync: `presentation/screens/connections/backup_section.dart`, on
  the Servers & devices hub after the paired devices.
- Recovery key sheet, restore screen (`/backup/restore`, reached from Add
  server and the sign-in screen), pending sources row and the vault choice
  dialog: `presentation/screens/backup/`.
