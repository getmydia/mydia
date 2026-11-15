# Cloud backup (player)

End-to-end encrypted backup of the player's watch state, pins, servers,
settings and sync group, stored on the metadata relay. The relay holds
ciphertext and public keys only. Design:
`design/specs/2026-11-14-player-cloud-backup-design.md`. Wire format and relay
rules: `metadata-relay/docs/backup.md`, which the client here is built
against. Native only: nothing in this directory runs on web (`kIsWeb`), and
the Backup & sync section is hidden there (`isWebProvider`).

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
  backed up, never leaves the install.
- `AuthStorage` `backup/vault`: vault id, epoch, the vault key per known
  epoch, this device's slot seq, the last success, and the recovery key text
  when this device holds it.
- Hive box `backup_meta` (`BackupMetaStore`): record stamps, pending account
  offers and dismissals, the seq of each slot already merged, each slot's
  device name, the p2p node to slot map and each slot's node claims, and
  whether the joined-by-pairing notice is still to be seen. Not backed up.

## Record kinds

Every record is last-writer-wins on its origin `updatedAt`, with tombstones.

| Kind | On a live device in the vault | On restore |
| --- | --- | --- |
| Watch | Merged | Merged |
| Pin | Merged | Merged |
| Account (record plus every secret under `source/<id>/`) | Offered: "2 sources added on Living Room TV", Add or Dismiss | Applied |
| Setting (only the keys in `kBackupSettingKeys`) | Ignored | Applied |
| Group (p2p group secret and roster, node to slot claims) | Already shared by pairing | Applied, so the device rejoins the p2p group |

Mydia accounts travel without tokens and come back flagged `needsReauth`.
Server locks, the Files index, downloads, caches, the iroh node key and the
backup identity are never backed up. A new setting is excluded until it is
added to the allowlist.

## Timing

An upload follows a change to a backed-up record, at most once per 2 minutes,
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
vault is not switched: `pendingVaultChoice` asks which to keep. Revoking a
paired device also removes it from the vault (`removeMemberForNode`), which
rotates the vault key. A hook that fails or times out never fails pairing.

## Failure behaviour

| Condition | Behaviour |
| --- | --- |
| Relay unreachable, 5xx, 429 | Backoff to 30 minutes; the status keeps the last success |
| 404 on `/backup/v1` (relay without the routes) | `BackupUnavailable`, "Cloud backup isn't available yet"; no retries until the next start or a user action |
| A slot fails to open | Skipped, the rest merge; "Couldn't read Living Room TV's backup" |
| 409 on rotation, or an unknown epoch | Refetch the manifest and envelope, retry once |
| 412 on upload | Refetch the manifest, upload again at the current seq |
| 403 not a member, vault gone | `BackupRemoved`: `backup/vault` is cleared, local data kept |
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
