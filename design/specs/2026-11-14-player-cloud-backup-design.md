# End-to-end encrypted cloud backup for the player

## Why

A player with no Mydia server still holds state worth keeping: its source
accounts and their tokens (Plex, Jellyfin, Stash, Files over local folders,
WebDAV and SMB), watch state and resume positions, manual "Fix match" pins,
the peer group secret, and its settings. Peer-to-peer watch sync
(`design/specs/2026-11-08-player-p2p-watch-sync-design.md`) copies some of it
between paired devices, but only between devices that are online at the same
time, and nothing survives losing or reinstalling every device.

## Goal

An opt-in, end-to-end encrypted backup stored by Mydia's metadata-relay that:

- Restores a player onto a fresh install from a recovery key alone, with no
  device left and no Mydia server.
- Acts as an always-reachable mailbox, so paired devices that are never online
  together still converge on watch state and pins.
- Is readable only by the user's devices. The relay stores ciphertext and
  learns no titles, tokens or device names.

It is available on every native player, including one that also has Mydia
servers added.

## Decisions

| Question | Decision |
| --- | --- |
| Job | Disaster recovery plus asynchronous sync between paired devices |
| Where blobs live | metadata-relay, as opaque ciphertext on its disk (the `PlayerLogs` pattern) |
| Recovery secret | A random 256-bit recovery key shown once (base32 groups and QR). No passphrase |
| Vault layout | One vault per peer sync group; one encrypted slot per device, written only by that device; readers LWW-merge every slot |
| Contents | Watch state and pins; source accounts with tokens; settings |
| Live sync vs restore | Watch state and pins apply live. Accounts are offered on live devices and applied on restore. Settings apply only on restore |
| Device identity | A per-install Ed25519 signer and X25519 box key, separate from the iroh node key |
| Revocation | Remove the signer from the relay's member list, delete its slot, rotate the vault key |
| Freshness | Polling with ETags (foreground, after a p2p sync, every 15 minutes while open). No push |
| Web | Not offered |

### Rejected

- **User's own cloud (iCloud, Google Drive, Dropbox, WebDAV, S3).** Per-platform
  SDK and OAuth work, and setup the user must do. A relay-hosted vault needs
  none.
- **A passphrase instead of, or alongside, the recovery key.** The relay would
  hold a blob open to offline guessing, and a second unlock path doubles the
  UI for a screen used once.
- **One shared vault blob with compare-and-swap.** Concurrent writers retry
  against each other and every write carries the whole group's state.
- **An encrypted append-only op log.** Progress ticks every 10 seconds reduce
  it to per-key LWW plus compaction and cursors, the same reason the p2p spec
  rejected an op log.
- **Reusing the iroh node key.** It would tie backup to the p2p stack, expose
  node ids to the relay, and need Ed25519 to X25519 conversion of a key Rust
  owns.
- **Auto-applying accounts and settings to live devices.** A phone and a TV
  legitimately differ in settings, and a source appearing on a device
  unannounced is a surprise. Accounts are offered instead.

## What the vault holds

Every record is LWW per key on its origin `updatedAt`, the rule
`PeerSyncStore` already uses, with tombstones for removal.

| Kind | Key | Contents | On a live paired device | On restore |
| --- | --- | --- | --- | --- |
| Watch | canonical watch key | `PeerWatchRecord` | Merged via `mergeRemote` | Merged |
| Pin | `(isShow, groupKey)` | `PeerPinRecord` | Merged via `mergeRemote` | Merged |
| Account | `accountId` | `HiveSourceStore` record JSON plus every `SourceSecrets` / `AuthStorage` token under `source/<accountId>/` | Listed as a pending offer | Applied |
| Setting | setting key | the stored value | Ignored | Applied |
| Group | `group` | the p2p `groupSecret` and roster | Already shared by pairing | Applied, so restore rejoins the p2p group |

- **Mydia accounts** are backed up without tokens: kind, instance id, URL or
  node address. Restore adds them flagged `needsReauth`. Their watch state
  lives on the server, and a server token copied to a second install is a
  device the server cannot revoke separately.
- **Jellyfin** tokens are bound to the `DeviceId` sent at sign-in, which the
  player keeps once per install (`JellyfinIdentity.deviceIdKey`), not per
  account. The backup does not carry it: sharing one install's id between two
  live devices would make the server treat them as one. A restored token is
  sent with the new install's id; if the server refuses it, the existing 401
  path flags `needsReauth`.
- **Plex Home**: only the active user's tokens are stored, as on the device.
- **Settings** exclude device-shaped keys (window geometry, TV focus state,
  download storage locations). An explicit allowlist in
  `BackupSnapshot` names the keys that are included; a new setting is
  excluded until added.
- **Excluded entirely**: lock modes (`serverLocks`), so a restore cannot
  unlock anything; the Files index and match cache, rebuilt by rescanning;
  downloads and caches; the iroh node key and the backup identity, which stay
  per install.

## Keys and crypto

All primitives come from the `cryptography` package already in
`player/pubspec.yaml`: Ed25519, X25519, HKDF-SHA256, XChaCha20-Poly1305.

### Device backup identity

Each install creates an Ed25519 signer and an X25519 box key on first use and
stores both in `AuthStorage` under `backup/identity`. The slot id is the
first 16 hex characters of `SHA-256(signer public key)`.

### Vault key

The vault key (VK) is 32 random bytes with an integer `epoch`, starting at 1.
A slot body is the JSON-encoded record list (the player has no CBOR
library), gzip'd, then sealed with
XChaCha20-Poly1305 under VK and a random 24-byte nonce. The AAD is
`"mydia/backup/slot/v1|" + vaultId + "|" + epoch + "|" + slotId + "|" + seq`,
so a blob cannot be moved to another slot or vault, or replayed from an older
epoch or sequence.

### Envelopes

VK is sealed once per member and once for recovery: an ephemeral X25519 key
agreement with the recipient's box public key, HKDF-SHA256 with info
`"mydia/backup/envelope/v1|" + vaultId + "|" + epoch`, then XChaCha20-Poly1305.
Any member can seal a new VK to the recovery public key without knowing the
recovery key. The relay stores every member's box public key, the recovery
one included, and lists them in the manifest, so whichever device rotates
can seal to all the others.

### Recovery key

32 random bytes, displayed as 52 Crockford base32 characters in groups of
four plus a QR code. HKDF-SHA256 over it derives, by distinct info strings:

- `mydia/backup/recovery-signer/v1`: an Ed25519 seed. The recovery signer is a
  vault member, so a fresh install can authenticate with the key alone.
- `mydia/backup/recovery-box/v1`: an X25519 private key that opens the
  recovery envelope.
- `mydia/backup/lookup/v1`: a 32-byte lookup handle. The relay stores only
  `SHA-256(handle)` and maps it to the vault id, so the user never handles a
  vault id.

Enabling backup shows the key, offers save, print and QR, and requires typing
back one group chosen at random before the vault is created. "Generate a new
recovery key" replaces the recovery signer, lookup hash and envelope in one
member update; the old key stops working at once. The key can be shown again
on any member device, since each member keeps it in `AuthStorage`.

### Revocation and rotation

Removing a device (from Settings, Paired devices, which also revokes it in the
p2p roster) does, in one `POST /members` call CAS'd on `epoch`:

1. Remove the device's signer from the member list.
2. Delete its slot.
3. Rotate to a fresh VK at `epoch + 1`, with envelopes for every remaining
   member and recovery.

Every member that next reads the manifest sees the new epoch, opens its
envelope, and re-uploads its slot under it. Slots still at the old epoch are
read with the old VK until replaced. A revoked device keeps what it already
decrypted, which no scheme can take back, and cannot read or write anything
after the rotation.

## Relay

A new `MetadataRelay.Backup` context following `MetadataRelay.PlayerLogs`:
ciphertext files under a `backup.dir` volume, rows in the relay's SQLite
(`backup_vaults`, `backup_members`, `backup_slots`), and an hourly sweeper.
Migrations use `:text` columns and a real timestamp.

### Authentication

Every request except vault creation and lookup carries

```
Authorization: MydiaSig signer=<base64url pub>, ts=<unix ms>, sig=<base64url>
```

where `sig` is Ed25519 over `method \n path \n hex(sha256(body)) \n ts`. The
relay rejects a `ts` more than 5 minutes from its clock and a signer that is
not a current member of the vault in the path. A skew rejection carries
`x-backup-server-time`, and the player retries once with that offset, so a
device with a wrong clock still backs up. Replayed reads leak nothing;
writes are guarded by sequence and epoch CAS.

### Endpoints (`/backup/v1`)

| Method and path | Who | Does |
| --- | --- | --- |
| `POST /vaults` | anyone, rate-limited per IP | Creates a vault: first member signer and envelope, recovery signer and envelope, `sha256(lookup handle)`, epoch 1. Returns the vault id (random 128 bits) |
| `GET /lookup/:handle` | holder of the handle | Returns the vault id |
| `GET /vaults/:id` | member | Manifest: epoch, member signers with their slot ids, the requester's own envelope, each slot's `seq`, `epoch`, size and `updated_at`. ETag, `If-None-Match` answers 304 |
| `PUT /vaults/:id/slots/:slot` | the slot's owner | Writes ciphertext. `If-Match: <seq>` (absent for the first write); 412 on mismatch |
| `GET /vaults/:id/slots/:slot` | member | Reads ciphertext. ETag |
| `POST /vaults/:id/members` | member | Add, remove, replace recovery, or rotate. A rotation carries the full envelope set; CAS on `epoch`, 409 on mismatch |
| `DELETE /vaults/:id` | member | Deletes the vault and every slot |

### Limits and retention

- 4 MB per slot, 16 members per vault, 120 writes per vault per hour.
  Exceeding them answers 413 or 429, which the player shows as a status.
- A vault with no write for 180 days is deleted by the sweeper. The settings
  screen states this.
- The relay logs no request bodies for these routes.

### Compatibility window

The relay deploys on its own `metadata-relay-v*` tag. A relay without the
routes answers 404 on `/backup/v1/...`, and the player shows "Cloud backup
isn't available yet" in place of the switch. Neither side needs the other to
upgrade first.

## Player

### Components (`player/lib/core/backup/`)

| Unit | Job | Depends on |
| --- | --- | --- |
| `BackupIdentity` | Creates and loads the device signer and box key | `AuthStorage` |
| `RecoveryKey` | Generates, encodes, parses and derives the signer, box key and lookup handle | `cryptography` |
| `VaultCrypto` | Seals and opens slots and envelopes. Pure, no I/O | `cryptography` |
| `BackupRelayClient` | Signed calls to `/backup/v1` at `metadataRelayBaseUrl` | `BackupIdentity`, the same HTTP client `RelayApiClient` uses |
| `BackupSnapshot` | Collects records from `PeerSyncStore`, `HiveSourceStore` plus `SourceSecrets`, and `SettingsService`; applies records in live or restore mode | those stores |
| `BackupSyncService` | Debounced upload, manifest polling, merge, rotation, pending account offers | all of the above, `PeerSyncService` |

Vault state (vault id, epoch, VK per known epoch, recovery key, own slot seq,
last success) lives in `AuthStorage` under `backup/vault`. A Hive box
`backup_meta` (added to `kMydiaHiveBoxes`) keeps the pending account offers
and per-slot `seq` already merged.

### Upload and poll

- An upload is triggered by a change to any backed-up record, debounced to at
  most one upload every 2 minutes, and forced when the app goes to the
  background. Playback progress ticks therefore cost at most one upload per 2
  minutes of playback.
- The manifest is polled on app foreground, after every p2p sync, and every 15
  minutes while the app is open. Only slots whose `seq` advanced are
  downloaded.

### Pairing

`PeerSyncRequest::Pair` gains optional `backup_signer` and `backup_box`
(base64url public keys), and `PeerSyncResponse::Paired` gains an optional
`vault_id`, all `#[serde(default)]` so peers on older builds still pair. When
the host has a vault and the joiner sent keys, the host seals VK to the
joiner, adds it as a member, and returns `vault_id`. The joiner then has
backup on with no recovery key typed, and shows a one-time notice: "This
device is now backed up with your group", linking to Backup & sync. This is
the only way backup turns on without the user enabling it on that device;
the group opted in when its first device did. A joiner that already had its own vault
is asked which to keep; the other is deleted after its records are merged.

### UX

- **Settings, Backup & sync** (a route and a pane in the desktop settings
  dialog, beside Paired devices): the switch, "Last backed up 3 min ago", each
  member device with its last upload, Show recovery key, Generate a new
  recovery key, Delete cloud backup.
- **Turning it on** runs the recovery key sheet. Backup is not enabled until
  the typed-back check passes.
- **Restore from backup** sits on the first-run and empty-sources screen and
  on Add server. Enter or scan the key, see a summary ("6 sources, 1,240 watch
  records, from 3 devices"), confirm. Restore merges into whatever is already
  on the device and joins this device to the vault and the p2p group.
- **Pending sources** on live devices: a row in Backup & sync and on the
  sources screen, "2 sources added on Living Room TV", with Add and Dismiss.
  Dismiss is remembered per account and record version.

### Errors

| Condition | Behaviour |
| --- | --- |
| Relay unreachable, 5xx, 429 | Exponential backoff to 30 minutes; status shows the last success |
| 404 on `/backup/v1` | "Cloud backup isn't available yet"; no retries until the next app start |
| A slot fails to open | Skip it, merge the rest, show "Couldn't read Living Room TV's backup" |
| 409 on rotation, or a slot at an unknown epoch | Refetch the manifest and envelope, retry once |
| 412 on upload | Refetch the manifest, re-upload at the current `seq` |
| 403 not a member | This device was removed: clear `backup/vault`, keep local data, show a banner |
| Lookup 404 | "No backup matches this key" |
| 413 slot too large | Status error naming the size; no partial upload |

## Testing

- **`VaultCrypto` and `RecoveryKey`**: round trips; tampered ciphertext, AAD,
  epoch, slot id and seq all fail; fixed vectors for the base32 encoding and
  every HKDF derivation, so a later refactor cannot silently change keys.
- **`BackupSnapshot`**: collect then apply round trip; live mode never adds an
  account or changes a setting; restore mode applies both; the settings
  allowlist excludes device-shaped keys; locks never travel; Mydia accounts
  restore without tokens and flagged `needsReauth`.
- **`BackupSyncService` against a fake relay**: two devices with no p2p link
  converge on watch state and pins; debounce limits uploads during simulated
  playback; revoke rotates the epoch, the revoked device gets 403 and cannot
  open the new epoch; restore onto an empty store yields the same records and
  joins the group; 404 on the base path disables the feature cleanly.
- **Relay ExUnit**: signature, clock skew and membership checks; slot
  ownership; `seq` and `epoch` CAS; limits; lookup; the sweeper deletes idle
  vaults and their files.
- **Rust**: a CBOR test that a `Pair` and a `Paired` without the new fields
  still decode.
