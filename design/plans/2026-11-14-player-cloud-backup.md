# Player Cloud Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An opt-in, end-to-end encrypted backup of a player's watch state, pins, source accounts and settings, stored as ciphertext on metadata-relay, restorable from a recovery key and used as an asynchronous sync mailbox between paired players.

**Architecture:** The relay gains a `MetadataRelay.Backup` context (SQLite rows plus ciphertext files, Ed25519-signed requests, sequence and epoch CAS). The player gains `lib/core/backup/`: pure crypto units, a signed relay client, a snapshot collector/applier over the existing stores, and a sync service wired into `PeerSyncService` for pairing and revocation. The p2p `Pair` handshake carries optional backup keys.

**Tech Stack:** Elixir/Plug/Ecto SQLite (relay), Rust serde (p2p core), Dart/Flutter/Riverpod with `package:cryptography` and `package:http` (player).

**Spec:** `design/specs/2026-11-14-player-cloud-backup-design.md`

## Global Constraints

- Crypto: Ed25519, X25519, HKDF-SHA256, XChaCha20-Poly1305 from `package:cryptography` (already a dependency). No new Dart crypto dependency. Relay verifies with `:crypto.verify(:eddsa, :none, msg, sig, [pub, :ed25519])`.
- Slot AAD: `"mydia/backup/slot/v1|" + vaultId + "|" + epoch + "|" + slotId + "|" + seq`.
- Envelope HKDF info: `"mydia/backup/envelope/v1|" + vaultId + "|" + epoch`.
- Recovery HKDF infos: `mydia/backup/recovery-signer/v1`, `mydia/backup/recovery-box/v1`, `mydia/backup/lookup/v1`.
- Recovery key: 32 bytes, 52 Crockford base32 chars, displayed in groups of four.
- Slot id: first 16 hex chars of `SHA-256(signer public key)`. Vault id: random 128 bits, lowercase hex.
- Auth header: `Authorization: MydiaSig signer=<b64url>, ts=<unix ms>, sig=<b64url>`; signed message `method \n path \n hex(sha256(body)) \n ts`; skew limit 5 minutes.
- Limits: 4 MB per slot (4_194_304 bytes), 16 members, 120 writes per vault per hour, 180-day idle expiry.
- Player timings: upload debounce 2 minutes, forced on background; poll on foreground, after a p2p sync, every 15 minutes; backoff to 30 minutes.
- AuthStorage keys: `backup/identity`, `backup/vault`. Hive box: `backup_meta` (add to `kMydiaHiveBoxes`, open through `initAppHive()` paths).
- Relay migrations: `:text` columns only, a real timestamp filename, check all remote branches for duplicates (AGENTS.md, Migration filenames).
- Not offered on web (`kIsWeb`).
- No em dashes in copy or docs. Fictional names only in tests ("Living Room TV", "Night Harbor").
- All new player strings go through ARB (`player/docs/l10n.md`).
- Commit with `git commit -F <msgfile>` inside the worktree (direnv loaded); verify with `git show --stat`.

## Review Focus

1. **Device clock far off.** A device whose clock is 10 minutes off must still back up: the relay returns `x-backup-server-time` on a skew 401 and the client retries once with that offset (Task 2 and Task 9 tests).
2. **Restore onto a device that already has some of the same accounts.** The local account and its tokens win; restore never overwrites a stored account record or token (Task 11 test `restore_keeps_existing_account`).
3. **App killed between a rotation's relay call and saving the new VK.** Next start sees epoch N+1 on the manifest with no local key, opens its envelope and continues (Task 12 test `recovers_epoch_after_crash_mid_rotation`).
4. **Large library near the 4 MB cap.** 20,000 watch records must compress well under the cap; an oversize slot yields a status error, not a retry loop (Task 12 test `oversize_slot_reports_and_stops`).
5. **Two devices revoking different members at the same moment.** One gets 409, refetches, re-applies its removal on the new epoch, and both removals land (Task 4 and Task 12 tests).

---

## Relay

### Task 1: Schema, migration and slot file store

**Files:**
- Create: `metadata-relay/priv/repo/migrations/<real timestamp>_create_backup_vaults.exs`
- Create: `metadata-relay/lib/metadata_relay/backup/vault.ex`, `member.ex`, `slot.ex`, `store.ex`
- Modify: `metadata-relay/config/config.exs`, `config/test.exs`, `config/runtime.exs` (`:backup` with `dir`, `sweep_interval_ms`; runtime `BACKUP_DIR` defaulting to `Path.join(Path.dirname(db_path), "backup")`, as `player_logs`)
- Test: `metadata-relay/test/metadata_relay/backup/store_test.exs`

**Interfaces:**
- Produces: tables `backup_vaults(id text pk, epoch integer, lookup_hash text unique, recovery_signer text, recovery_envelope text, last_write_at utc_datetime_usec, inserted_at, updated_at)`, `backup_members(vault_id text fk on delete cascade, signer text, slot_id text, envelope text, inserted_at; unique (vault_id, signer), unique (vault_id, slot_id))`, `backup_slots(vault_id text fk cascade, slot_id text, seq integer, epoch integer, size integer, path text, updated_at; pk (vault_id, slot_id))`. Envelopes stored as base64url text.
- Produces: `MetadataRelay.Backup.Store.write(relative :: Path.t(), binary) :: :ok | {:error, term}`, `read(relative) :: {:ok, binary} | {:error, :enoent}`, `delete(relative) :: :ok`, `delete_vault_dir(vault_id) :: :ok`, `slot_path(vault_id, slot_id, seq) :: Path.t()` returning `"<vault_id>/<slot_id>-<seq>.bin"`. Writes go to `.tmp` then rename, as `PlayerLogs.Store`. No gzip on the relay; bodies are already compressed ciphertext.

- [ ] **Step 1:** Write `store_test.exs`: `write/2` then `read/1` round-trips 1 KB of random bytes; `delete_vault_dir/1` removes every file of that vault only; `slot_path/3` rejects a vault id or slot id that is not lowercase hex (raises `ArgumentError`).
- [ ] **Step 2:** Run `./dev mix test test/metadata_relay/backup/store_test.exs` from `metadata-relay/`'s dev command (`cd metadata-relay && mix test ...` inside devenv). Expected: FAIL, module undefined.
- [ ] **Step 3:** Write the migration (plain `create table`, works on SQLite), the three Ecto schemas, the config entries and `Store`.
- [ ] **Step 4:** Run the test and `mix ecto.migrate` against the test DB. Expected: PASS.
- [ ] **Step 5:** Commit `feat(relay): backup vault schema and slot store`.

### Task 2: Request signature verification

**Files:**
- Create: `metadata-relay/lib/metadata_relay/backup/auth.ex`
- Test: `metadata-relay/test/metadata_relay/backup/auth_test.exs`

**Interfaces:**
- Produces: `MetadataRelay.Backup.Auth.parse(header :: String.t() | nil) :: {:ok, %{signer: binary, ts: integer, sig: binary}} | {:error, :missing | :malformed}` (signer and sig decoded from base64url, signer 32 bytes, sig 64 bytes).
- Produces: `verify(parsed, method :: String.t(), path :: String.t(), body :: binary, now_ms :: integer) :: :ok | {:error, :skew | :bad_signature}`. Message is `"#{method}\n#{path}\n#{hex(sha256(body))}\n#{ts}"` with lowercase hex; skew is `abs(now_ms - ts) > 300_000`.

- [ ] **Step 1:** Tests, generating a keypair with `:crypto.generate_key(:eddsa, :ed25519)`: valid signature is `:ok`; changed body, path, method or ts is `{:error, :bad_signature}`; ts 300_001 ms off is `{:error, :skew}`; a 31-byte signer is `{:error, :malformed}`; nil header is `{:error, :missing}`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(relay): verify MydiaSig backup request signatures`.

### Task 3: Vault creation, lookup, manifest and slots

**Files:**
- Create: `metadata-relay/lib/metadata_relay/backup.ex`
- Test: `metadata-relay/test/metadata_relay/backup/backup_test.exs`

**Interfaces:**
- Consumes: Task 1 schemas and `Store`.
- Produces (all in `MetadataRelay.Backup`):
  - `create_vault(%{signer: b, slot_id: s, envelope: e, recovery_signer: b, recovery_slot_id: s, recovery_envelope: e, lookup_hash: hex}) :: {:ok, vault_id} | {:error, :lookup_taken | :invalid}`. The recovery signer is stored as a member too (so it can sign) with its own slot id; it never writes a slot.
  - `lookup(handle :: binary) :: {:ok, vault_id} | {:error, :not_found}` (hashes the handle with SHA-256, hex).
  - `member?(vault_id, signer) :: boolean`.
  - `manifest(vault_id, signer) :: {:ok, %{epoch, members: [%{signer, slot_id}], envelope, recovery_signer, slots: [%{slot_id, seq, epoch, size, updated_at}]}, etag :: String.t()} | {:error, :not_found}`. `envelope` is the requester's own. ETag is `"\"#{epoch}-#{max slot seq sum}-#{member count}-#{updated_at max}\""` or any value that changes with every write; tests only assert it changes.
  - `put_slot(vault_id, signer, slot_id, body, if_match :: integer | nil, epoch :: integer) :: {:ok, seq} | {:error, :not_owner | :precondition_failed | :too_large | :stale_epoch | :rate_limited}`. Owner means the member row's `slot_id` equals the path slot and signer matches. `if_match` nil only when no slot row exists. New seq is old + 1 (first is 1). `epoch` (sent as header `x-backup-epoch`) must equal the vault epoch. Charges `RateLimiter.check_rate_limit("backup:vault:#{id}", limit: 120, window_ms: 3_600_000)`. Updates `last_write_at`. Deletes the previous seq's file after the row update.
  - `get_slot(vault_id, slot_id) :: {:ok, body, seq} | {:error, :not_found}`.
  - `delete_vault(vault_id) :: :ok`.

- [ ] **Step 1:** Tests: create then lookup by handle; second create with same lookup hash is `:lookup_taken`; manifest returns only the caller's envelope; `put_slot` first write with nil if_match is seq 1, then if_match 1 gives 2, stale if_match 1 again gives `:precondition_failed`; another member writing this slot is `:not_owner`; 4_194_305 bytes is `:too_large`; epoch mismatch is `:stale_epoch`; the 121st write in an hour is `:rate_limited`; manifest ETag differs before and after a write; `delete_vault` removes rows and files.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement with `Repo.transaction` around each read-modify-write; the seq check is a conditional `update_all` (`where seq == ^if_match`) whose row count decides, not a read then write.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(relay): backup vaults, lookup and slot CAS`.

### Task 4: Member changes and rotation

**Files:**
- Modify: `metadata-relay/lib/metadata_relay/backup.ex`
- Test: `metadata-relay/test/metadata_relay/backup/members_test.exs`

**Interfaces:**
- Produces: `update_members(vault_id, signer, %{expected_epoch: integer, new_epoch: integer, add: [%{signer, slot_id}], remove: [signer], envelopes: %{signer => envelope}, recovery: nil | %{signer, slot_id, envelope, lookup_hash}}) :: {:ok, epoch} | {:error, :conflict | :too_many_members | :invalid}`.
  - `expected_epoch` must equal the vault epoch, else `:conflict` (HTTP 409).
  - `new_epoch` is `expected_epoch` (add with an envelope under the current key, no rotation) or `expected_epoch + 1` (rotation). On rotation `envelopes` must hold exactly one entry per remaining member including recovery, else `:invalid`.
  - Removing a member deletes its slot row and file. A signer cannot remove the recovery signer except via `recovery` replacement.
  - `recovery` replaces the recovery member, its envelope and `lookup_hash` atomically.
  - More than 16 members after the change is `:too_many_members`.

- [ ] **Step 1:** Tests: add a member at the same epoch; rotation with full envelope set bumps epoch and replaces every envelope; rotation missing one envelope is `:invalid`; two updates both sent with `expected_epoch: 1` leave one `{:ok, 2}` and one `:conflict`, and the loser retried with `expected_epoch: 2` succeeds; removed member's slot file is gone and `member?` is false; recovery replacement makes the old lookup handle `:not_found`; 17th member is `:too_many_members`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement; epoch CAS is `update_all(where epoch == ^expected)` inside the transaction.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(relay): backup member changes with epoch CAS`.

### Task 5: HTTP handler, routes and sweeper

**Files:**
- Create: `metadata-relay/lib/metadata_relay/backup/handler.ex`, `metadata-relay/lib/metadata_relay/backup/sweeper.ex`
- Modify: `metadata-relay/lib/metadata_relay/router.ex` (Parsers `pass:` gains `"application/octet-stream"` and `"application/vnd.mydia.backup+json"`; `forward "/backup/v1", to: MetadataRelay.Backup.Handler` placed before the catch-all), `metadata-relay/lib/metadata_relay/application.ex` (add `Backup.Sweeper` beside `PlayerLogs.Sweeper`)
- Modify: `metadata-relay/README.md` or `metadata-relay/docs/` (one section: endpoints, limits, the relay never sees plaintext)
- Test: `metadata-relay/test/metadata_relay/backup/handler_test.exs`, `sweep_test.exs`

**Interfaces:**
- Consumes: Tasks 2 to 4.
- Produces: the endpoint table from the spec. JSON bodies use `application/vnd.mydia.backup+json` so the handler reads the raw body itself (needed for the signature hash), capped at 64 KB; slot bodies are `application/octet-stream`, capped at 4 MB while reading. Binary fields in JSON are base64url. Error mapping: missing/malformed auth 401, skew 401 with header `x-backup-server-time: <unix ms>`, non-member 403, unknown vault 404, `:precondition_failed` 412, `:conflict` 409, `:too_large` 413, `:rate_limited` 429, `:invalid` 422. `POST /vaults` is rate-limited per `ClientIp.resolve/1` at 10 per hour. `GET /lookup/:handle` is rate-limited per IP at 30 per hour. Request bodies are never logged.
- Produces: `MetadataRelay.Backup.sweep(now \\ DateTime.utc_now()) :: {:ok, deleted :: non_neg_integer}` deleting vaults with `last_write_at` (or `inserted_at` if never written) older than 180 days, files included.

- [ ] **Step 1:** Handler tests with `Plug.Test.conn` through `MetadataRelay.Router`, signing with a test keypair helper: full create → lookup → PUT slot → GET manifest (200, ETag) → GET manifest with `If-None-Match` (304) → GET slot → DELETE vault; skewed ts returns 401 with `x-backup-server-time`; unsigned GET manifest is 401; a non-member signer is 403; oversize PUT is 413 before the whole body is read. Sweep test: a vault last written 181 days ago is deleted with its directory, one at 179 days stays.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement handler (a `Plug.Router` module), routes, sweeper (copy `PlayerLogs.Sweeper` shape, config key `:backup`), docs.
- [ ] **Step 4:** Run `mix test test/metadata_relay/backup` and the full relay suite. Expected: PASS.
- [ ] **Step 5:** Commit `feat(relay): /backup/v1 routes and idle-vault sweeper`.

## Rust

### Task 6: Optional backup fields on Pair and Paired

**Files:**
- Modify: `native/mydia_p2p_core/src/peer_sync.rs`
- Modify: `player/rust/mydia_player_p2p/src/lib.rs` (`FlutterPeerSyncRequest::Pair`, `FlutterPeerSyncResponse::Paired`, both `From` impls)
- Regenerate: flutter_rust_bridge bindings under `player/lib/native/` per `player/docs/workflow.md`
- Test: `native/mydia_p2p_core/src/peer_sync.rs` tests module

**Interfaces:**
- Produces: `Pair { ..., #[serde(default)] backup_signer: Option<String>, #[serde(default)] backup_box: Option<String> }`, `Paired { ..., #[serde(default)] vault_id: Option<String> }`. Dart sees `FlutterPeerSyncRequest.pair(..., backupSigner:, backupBox:)` and `FlutterPeerSyncResponse_Paired.vaultId`.

- [ ] **Step 1:** Tests: a `Pair` serialized from a struct copy of the old shape (define `OldPair` in the test with the four original fields) decodes into the new `Pair` with both new fields `None`; same for `Paired` and `vault_id`; round trip with all fields set.
- [ ] **Step 2:** Run `cargo test -p mydia_p2p_core peer_sync`. Expected: FAIL to compile on the missing fields.
- [ ] **Step 3:** Add fields, update the Flutter mirror and conversions, regenerate bindings, update the two existing Dart call sites in `peer_sync_service.dart` to pass `backupSigner: null, backupBox: null` and `vaultId: null` for now.
- [ ] **Step 4:** Run cargo tests and `./dev flutter test test/core/p2p`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(p2p): optional backup keys on the peer Pair handshake`.

## Player

### Task 7: Recovery key and vault crypto

**Files:**
- Create: `player/lib/core/backup/recovery_key.dart`, `player/lib/core/backup/vault_crypto.dart`, `player/lib/core/backup/backup_gzip.dart` (conditional import: `backup_gzip_io.dart` using `dart:io` `gzip`, `backup_gzip_stub.dart` throwing `UnsupportedError`)
- Test: `player/test/core/backup/recovery_key_test.dart`, `player/test/core/backup/vault_crypto_test.dart`

**Interfaces:**
- Produces `RecoveryKey`:
  - `RecoveryKey.generate()`, `RecoveryKey.parse(String text)` (ignores spaces, dashes, case; maps `O`→`0`, `I`/`L`→`1`; throws `FormatException` on wrong length or alphabet), `String get display` (13 groups of 4 separated by spaces), `Uint8List get bytes`.
  - `Future<SimpleKeyPair> signer()`, `Future<SimpleKeyPair> boxKey()`, `Future<Uint8List> lookupHandle()` via HKDF-SHA256 (salt empty, 32-byte output) with the Global Constraints infos.
- Produces `VaultCrypto` (static, pure):
  - `Future<Uint8List> sealSlot({required List<int> vaultKey, required String vaultId, required int epoch, required String slotId, required int seq, required List<int> plaintext})` returning `nonce(24) || ciphertext || mac(16)`; `openSlot(...)` same params with `sealed`, throws `VaultCryptoException` on any failure.
  - `Future<Uint8List> sealEnvelope({required List<int> vaultKey, required SimplePublicKey recipientBox, required String vaultId, required int epoch})` returning `ephemeralPub(32) || nonce(24) || ciphertext || mac`; `openEnvelope({required SimpleKeyPair box, ...})`.
  - `String slotIdFor(List<int> signerPublicKey)`.
- Produces `List<int> gzipEncode(List<int>)`, `List<int> gzipDecode(List<int>)`.

- [ ] **Step 1:** Recovery key tests: `parse(generate().display)` round-trips bytes; `parse` accepts lower case and `O`/`I`/`L` substitutions; 51 chars throws; fixed vector: bytes `0x00..0x1f` encode to a pinned 52-char string and derive pinned hex for the signer public key, box public key and lookup handle. Compute the pinned values once with an independent implementation (Python `cryptography` HKDF/Ed25519/X25519, run with `python -I` from the scratchpad) and paste them; the test comment names the inputs, not the tool.
- [ ] **Step 2:** Vault crypto tests: slot seal/open round trip; flipping one byte of ciphertext, or opening with a different `epoch`, `slotId`, `seq` or `vaultId`, throws `VaultCryptoException`; envelope round trip; opening an envelope with another box key throws; `slotIdFor` is 16 lowercase hex chars.
- [ ] **Step 3:** Run `./dev flutter test test/core/backup`. Expected: FAIL.
- [ ] **Step 4:** Implement.
- [ ] **Step 5:** Run. Expected: PASS.
- [ ] **Step 6:** Commit `feat(player): recovery key and backup vault crypto`.

### Task 8: Backup identity and vault state persistence

**Files:**
- Create: `player/lib/core/backup/backup_identity.dart`, `player/lib/core/backup/backup_vault_state.dart`
- Test: `player/test/core/backup/backup_identity_test.dart`, `backup_vault_state_test.dart`

**Interfaces:**
- Produces `BackupIdentity` with `static Future<BackupIdentity> loadOrCreate(AuthStorage)`, `SimpleKeyPair signer`, `SimpleKeyPair box`, `String slotId`, `Future<String> signerPublicB64()`, `Future<String> boxPublicB64()`. Stored as JSON of base64url seeds under `backup/identity`.
- Produces `BackupVaultState` (immutable): `vaultId`, `epoch`, `Map<int, Uint8List> keysByEpoch`, `String recoveryKeyText`, `int ownSeq`, `int? lastSuccessMs`, `String? manifestEtag`; `toJson`/`fromJson`; `BackupVaultStateStore(AuthStorage)` with `Future<BackupVaultState?> load()`, `save(BackupVaultState)`, `clear()` under `backup/vault`. Keys older than the newest two epochs are dropped on save.

- [ ] **Step 1:** Tests with an in-memory `AuthStorage`: `loadOrCreate` twice returns the same public keys; state round-trips through `save`/`load`; saving epochs 1, 2, 3 keeps only 2 and 3; `clear` makes `load` null.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(player): backup identity and vault state`.

### Task 9: Signed relay client

**Files:**
- Create: `player/lib/core/backup/backup_relay_client.dart`
- Test: `player/test/core/backup/backup_relay_client_test.dart`

**Interfaces:**
- Consumes: `BackupIdentity`, `RecoveryKey.signer()`.
- Produces `BackupRelayClient({http.Client? client, String baseUrl = metadataRelayBaseUrl, DateTime Function()? clock})`. Every method takes the `SimpleKeyPair signer` to sign with:
  - `createVault(CreateVaultRequest) -> Future<String vaultId>`
  - `lookup(Uint8List handle) -> Future<String vaultId>`
  - `manifest(vaultId, signer, {String? etag}) -> Future<BackupManifest?>` (null on 304)
  - `putSlot(vaultId, signer, slotId, Uint8List body, {required int? ifMatch, required int epoch}) -> Future<int seq>`
  - `getSlot(vaultId, signer, slotId) -> Future<Uint8List>`
  - `updateMembers(vaultId, signer, MemberUpdate) -> Future<int epoch>`
  - `deleteVault(vaultId, signer) -> Future<void>`
  - Data classes `CreateVaultRequest`, `BackupManifest`, `ManifestSlot`, `ManifestMember`, `MemberUpdate` mirror Task 3 and Task 4 field names.
  - Failures throw `BackupRelayException(BackupRelayError kind, {int? retryAfterMs})` with kinds `unavailable` (404 on any `/backup/v1` path when the body is not the relay's JSON `vault_not_found`), `notFound`, `notMember` (403), `conflict` (409), `preconditionFailed` (412), `tooLarge` (413), `rateLimited` (429), `network`, `server`.
  - Skew handling: on 401 carrying `x-backup-server-time`, store `offsetMs = serverTime - clock()` and retry once; later signatures use `clock() + offsetMs`.

- [ ] **Step 1:** Tests with `MockClient`: the `Authorization` header verifies against the signer's public key for the exact method, path and body (verify with `Ed25519().verify`); 304 returns null; each status maps to its kind; a 404 with an HTML body is `unavailable` while 404 `{"error":"vault_not_found"}` is `notFound`; a skew 401 is retried once with the corrected ts and succeeds; a second skew 401 throws.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Task 5's handler must answer unknown vaults with `{"error":"vault_not_found"}`; if it does not, fix it there.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(player): signed backup relay client`.

### Task 10: Backup records

**Files:**
- Create: `player/lib/core/backup/backup_records.dart`
- Test: `player/test/core/backup/backup_records_test.dart`

**Interfaces:**
- Produces sealed class `BackupRecord` with `String key`, `int updatedAt`, `bool deleted`, `toJson`, `fromJson` (unknown `type` returns null so newer builds' records are skipped, not fatal). Subtypes: `WatchBackupRecord` (fields of `PeerWatchRecord` minus `landedAt`), `PinBackupRecord`, `AccountBackupRecord { Map<String,dynamic> recordJson; Map<String,String> secrets; }` where `secrets` keys are storage keys relative to the account's `storageNamespace`, `SettingBackupRecord { String settingKey; String? value; }`, `GroupBackupRecord { String groupSecretB64; Map<String, String> nodeToSlot; }` (p2p node id to backup slot id, filled in by Task 13).
- Produces `class BackupPayload { String deviceName; String platform; int createdAt; List<BackupRecord> records; }` with `encode() -> List<int>` (UTF-8 JSON then `gzipEncode`) and `static BackupPayload decode(List<int>)`.
- Produces `List<BackupRecord> lwwMerge(Iterable<Iterable<BackupRecord>> slots)`: per key, highest `updatedAt`; tie goes to `deleted: true`, then to the lexicographically larger JSON so all devices pick the same one.

- [ ] **Step 1:** Tests: encode/decode round trip of one of each type; an unknown type is dropped on decode; `lwwMerge` picks newer, prefers tombstone on tie, and is order-independent (merge `[a,b]` equals `[b,a]`); a 20,000-watch-record payload encodes under 1 MB.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(player): backup record model and LWW merge`.

### Task 11: Snapshot collect and apply

**Files:**
- Create: `player/lib/core/backup/backup_snapshot.dart`, `player/lib/core/backup/backup_meta_store.dart`
- Modify: `player/lib/core/storage/hive_box_migration.dart` (`'backup_meta'` in `kMydiaHiveBoxes`), the startup box opening alongside `PeerSyncStore.boxName`
- Test: `player/test/core/backup/backup_snapshot_test.dart`

**Interfaces:**
- Consumes: `PeerSyncStore` (`allWatchRecords`, `allPinRecords`, `mergeRemote`), `SourceStore.load`, `SourceRecordsNotifier.putAccount`, `AuthStorage`, `PeerGroupSecret.storageKey`, Task 10.
- Produces `BackupMetaStore` (Hive `backup_meta`): `stamp(String key, String fingerprint, int nowMs) -> int updatedAt` (returns the stored `updatedAt` when the fingerprint is unchanged, else stores and returns `nowMs`); `pendingAccounts() -> List<PendingAccountOffer>`; `putPending`, `dismiss(accountId, updatedAt)`, `isDismissed(accountId, updatedAt)`; `mergedSeq(slotId) / setMergedSeq(slotId, seq)`.
- Produces `BackupSnapshot` with:
  - `Future<List<BackupRecord>> collect({required int nowMs})`. Accounts: every account except `SourceKind.mydia` secrets; Mydia accounts have `secrets` empty and the record JSON marked `needsReauth: true`; `serverLocks` removed from every record JSON; secrets are every `AuthStorage` key the account owns (account token, each profile's user token, each server token, Jellyfin device id key from `JellyfinIdentity`). Removed accounts become tombstones once (fingerprint `deleted`). Settings: `const kBackupSettingKeys = ['default_quality', 'auto_skip_segments', 'subtitle_size', 'theme_preset', 'interface_locale', 'update_track']` plus every `library_sort_*` key known to `SettingsService` and the subtitle language list from `subtitle_language_prefs.dart`. `updatedAt` for accounts, settings and group comes from `BackupMetaStore.stamp` with a SHA-256 fingerprint of the value.
  - `Future<ApplyResult> apply(List<BackupRecord> merged, {required BackupApplyMode mode, required String fromDevice, required int nowMs})`, `enum BackupApplyMode { live, restore }`. Watch and pin go through `PeerSyncStore.mergeRemote` in both modes (then the existing `applyRemoteFilesChanges`). Accounts: `restore` writes secrets then `putAccount` only for account ids not already stored; `live` records a `PendingAccountOffer` for new non-dismissed ids and never writes. Account tombstones are never applied (removal stays local). Settings: `restore` only, and only keys in the allowlist. Group: `restore` only, writes `PeerGroupSecret.storageKey` when none is stored.
  - `ApplyResult { int watchChanged; int pinsChanged; int accountsAdded; int settingsApplied; List<PendingAccountOffer> newOffers; }`.

- [ ] **Step 1:** Tests (in-memory stores, `InMemoryPeerSyncStore`, `InMemorySourceStore`, fake `AuthStorage`): collect then restore-apply on an empty device reproduces the Plex account with its server token and the settings; locks never appear in collected JSON; a Mydia account is collected without secrets and restored with `needsReauth`; `live` apply adds no account and changes no setting but returns a `PendingAccountOffer` named with `fromDevice` "Living Room TV"; `restore_keeps_existing_account`: an account id already stored keeps its local token; collecting twice with no change keeps `updatedAt`; a `glass_material` value is never collected.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(player): collect and apply backup snapshots`.

### Task 12: Backup sync service

**Files:**
- Create: `player/lib/core/backup/backup_sync_service.dart`, `player/lib/core/backup/backup_providers.dart`
- Modify: `player/lib/app.dart` (start the service after `peerSyncServiceProvider.start()`, native only; forward app lifecycle `paused` and `resumed`)
- Test: `player/test/core/backup/backup_sync_service_test.dart`, `player/test/core/backup/fake_backup_relay.dart`

**Interfaces:**
- Consumes: Tasks 7 to 11, `PeerSyncService` (`stateChanged` stream, `revokePeer`, `activeMemberIds`).
- Produces `BackupSyncService` and `backupSyncServiceProvider`, with `ValueListenable<BackupStatus> status` where `BackupStatus` is a sealed class: `Off`, `Unavailable`, `Idle(lastSuccessMs)`, `Uploading`, `Error(BackupRelayError, lastSuccessMs)`, `Removed`. Methods:
  - `Future<RecoveryKey> prepareEnable()`: generates the key without contacting the relay.
  - `Future<void> confirmEnable(RecoveryKey key)`: creates the vault with this device and recovery as members at epoch 1, saves state, uploads.
  - `Future<RestorePreview> previewRestore(String keyText)` (lookup, add this device as a member using the recovery signer, download and decrypt every slot, merge, count) and `Future<ApplyResult> commitRestore(RestorePreview)` (apply in `restore` mode, save state, upload own slot).
  - `void markDirty()` (2-minute debounce), `Future<void> flush()` (called on `paused`), `Future<void> poll()` (manifest with ETag; download slots whose seq is above `mergedSeq`; skip and report per-slot open failures; apply in `live` mode).
  - `Future<void> removeMember(String slotId)`: rotation with fresh VK, envelopes for every remaining member and recovery; on `conflict` refetch manifest and retry once.
  - `Future<RecoveryKey> regenerateRecoveryKey()`, `Future<void> deleteBackup()`, `Future<void> disable()` (leaves the vault: removes self with rotation, then clears local state).
  - Triggers: `PeerSyncStore` mutations call `markDirty`; `SourceRecordsNotifier` changes call `markDirty`; `poll` on resume, after `PeerSyncService.stateChanged`, and every 15 minutes; errors back off 1, 2, 4 ... capped at 30 minutes; `Unavailable` stops retrying until next start; `notMember` clears `backup/vault` and moves to `Removed`.
- `FakeBackupRelay` implements the relay semantics of Tasks 3 to 5 in memory behind a `MockClient`, so tests exercise the real `BackupRelayClient`.

- [ ] **Step 1:** Tests with two services sharing one `FakeBackupRelay` and fake async time: device A enables and records a watch, B joins by `previewRestore`/`commitRestore` with A's key and sees the record; B marks an item watched, after debounce and A's poll A sees it, with no p2p transport involved; 30 progress updates within 2 minutes produce one upload; `removeMember` on A bumps the epoch and B then receives `notMember` and goes to `Removed`, while a third device C still opens the new epoch; `recovers_epoch_after_crash_mid_rotation`: state saved at epoch 1 while the relay is at 2 recovers on next poll; `oversize_slot_reports_and_stops`: a 413 sets `Error(tooLarge)` and schedules no immediate retry; concurrent `removeMember` on A and C both land after one 409 retry; a relay with no `/backup/v1` gives `Unavailable`; a corrupted slot of one device is skipped and the rest merge.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement the service and the fake.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(player): backup sync service`.

### Task 13: Pairing joins the vault

**Files:**
- Modify: `player/lib/core/p2p/peer_sync_service.dart` (`_completePairHandshake`, `_handlePairRequest`, `revokePeer`; new optional constructor hooks)
- Test: `player/test/core/p2p/peer_sync_backup_pairing_test.dart`

**Interfaces:**
- Consumes: Task 6 fields, Task 12.
- Produces on `PeerSyncService` constructor: `Future<({String signer, String box})?> Function()? backupKeysForPair`, `Future<String?> Function(String signerB64, String boxB64)? onJoinerBackupKeys` (host: adds the joiner as a member with an envelope at the current epoch, returns the vault id or null), `Future<void> Function(String vaultId)? onJoinedVault` (joiner), and `Future<void> Function(String nodeId)? onPeerRevoked`. `backupSyncServiceProvider` passes these when it builds the service; `peerSyncServiceProvider` reads them from a small `backupPairingHooksProvider` to avoid a provider cycle.
- Produces on `BackupSyncService`: `Future<String?> addMemberForPair(String signerB64, String boxB64)`, `Future<void> adoptVault(String vaultId)` (manifest with own signer, open envelope, save state, upload, set `showJoinedNotice`), `bool showJoinedNotice` plus `void acknowledgeJoinedNotice()`. When the joiner already has a different vault, `adoptVault` returns without switching and sets `pendingVaultChoice` (`({String current, String offered})?`) for the UI. The peer roster must map a node id to a backup slot id for revocation, so `Pair` keys are recorded in `backup_meta` as `nodeId -> slotId` on the host, and each device adds its own entry to `GroupBackupRecord.nodeToSlot`.

- [ ] **Step 1:** Tests with the existing fake peer transport from `peer_sync_service_test.dart` plus `FakeBackupRelay`: host with backup pairs a joiner without backup, and the joiner ends with backup on, `showJoinedNotice` true, and the relay lists it as a member; a host without backup sends `vaultId: null` and the joiner stays `Off`; revoking the joiner's node on the host calls `removeMember` with its slot id and rotates the epoch; a joiner with its own vault gets `pendingVaultChoice` and is not switched.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run this test and `test/core/p2p/peer_sync_service_test.dart`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(player): paired devices join the backup vault`.

### Task 14: Backup & sync UI, restore flow and docs

**Files:**
- Create: `player/lib/presentation/screens/connections/backup_section.dart`, `player/lib/presentation/screens/backup/recovery_key_sheet.dart`, `player/lib/presentation/screens/backup/restore_backup_screen.dart`, `player/lib/presentation/screens/backup/pending_sources_row.dart`
- Modify: `player/lib/presentation/screens/connections/connections_hub.dart` (new section after devices, key `connections-backup-section`, hidden on web), `player/lib/core/router/app_router.dart` (`/backup/restore`), `player/lib/presentation/screens/sources/add_source_screen.dart` (a "Restore from backup" entry, native only), the empty-sources/first-run screen that `add_source_screen.dart` is reached from, `player/lib/l10n/*.arb`
- Create: `player/lib/core/backup/README.md` (keys, record kinds, what syncs live versus on restore, the relay contract); add a row for it to the table in `AGENTS.md`
- Test: `player/test/presentation/screens/backup/` widget tests

**Interfaces:**
- Consumes: `backupSyncServiceProvider`, `BackupStatus`, `RestorePreview`, `PendingAccountOffer`.
- Copy pinned by the spec: "Cloud backup isn't available yet", "This device is now backed up with your group", "No backup matches this key", "Couldn't read {device}'s backup", "{count} sources added on {device}", the restore summary "{sources} sources, {records} watch records, from {devices} devices", and the 180-day idle notice.

- [ ] **Step 1:** Widget tests: the section shows the switch when `Off` and the unavailable copy when `Unavailable`; turning on opens the recovery key sheet and the confirm button stays disabled until the randomly chosen group is typed correctly; the restore screen rejects a malformed key inline, shows the "no backup" copy on `notFound`, and shows the summary before Restore is pressed; a pending offer row lists the device name and Add calls `putAccount`; the joined notice shows once and not after acknowledgement; the section is absent on web (`isWebProvider` overridden true).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement screens, route, ARB strings (run the l10n check from `player/docs/l10n.md`), README and AGENTS.md row.
- [ ] **Step 4:** Run the widget tests, `./dev flutter analyze`, and the full `./dev flutter test`. Expected: PASS, no analyzer issues.
- [ ] **Step 5:** Commit `feat(player): backup & sync settings, recovery key and restore`.

### Task 15: Branch verification

- [ ] **Step 1:** Run `./dev mix precommit` (in chunks if it exceeds the Bash timeout), the relay suite, `cargo test -p mydia_p2p_core`, and `./dev flutter test`. Expected: all PASS.
- [ ] **Step 2:** Run Repowise `get_risk` with `changed_files` from `git diff --name-only origin/master...`; touch or justify each `missing_cochanges` entry.
- [ ] **Step 3:** Diff against `origin/master` and confirm every file in `--stat` belongs to a task above.
