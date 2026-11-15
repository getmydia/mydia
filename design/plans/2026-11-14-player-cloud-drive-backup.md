# iCloud and Google Drive backup stores Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a player group back up to the user's iCloud or Google Drive instead of the Mydia relay, so signing in to the same account restores or joins a device.

**Architecture:** Split #1414's `BackupSyncService` into a store-agnostic `SlotSyncEngine` over a `SlotTransport` interface. The relay path keeps its features behind `RelaySlotTransport` plus a slimmer `BackupSyncService`. A new `CloudBackupService` runs the engine over `CloudSlotTransport`, which stores plaintext slots through either a `GoogleDriveBackend` (Drive v3 `appDataFolder`) or a `CloudKitBackend` (Swift handler in the Runner targets). `BackupController` holds the one active store.

**Tech Stack:** Dart/Flutter 3.47, Riverpod, `http`, `crypto`, `url_launcher`, `google_sign_in` ^7, Swift CloudKit (iOS and macOS), Rust `mydia_p2p_core` (one optional field).

**Spec:** `design/specs/2026-11-14-player-cloud-drive-backup-design.md`. Builds on `design/specs/2026-11-14-player-cloud-backup-design.md` (#1414); read both.

## Global Constraints

- Branch `feat/player-cloud-drive-backup`, stacked on `feat/player-cloud-backup` (#1414). Rebase onto it when #1414 moves.
- Store ids are exactly `relay`, `icloud`, `gdrive`, persisted in `AuthStorage` key `backup/store`.
- Google scope is exactly `https://www.googleapis.com/auth/drive.appdata`. No other Google scope, ever.
- Google client ids and installed-app client secrets come from `--dart-define`: `MYDIA_GDRIVE_CLIENT_ID_ANDROID`, `_IOS`, `_DESKTOP`, `_TV`, `MYDIA_GDRIVE_CLIENT_SECRET_DESKTOP`, `_TV`. An empty define hides Google Drive on that platform.
- Google tokens live in `AuthStorage` key `backup/gdrive` (JSON: `email`, `refreshToken`, `clientKind`). google_sign_in platforms store no refresh token there, only `email`.
- CloudKit container `iCloud.dev.mydia.player`, private database, zone `Backup`, record type `Slot`, record name `slot-<slotId>`, fields `slotId`, `deviceName`, `platform`, `updatedAt` (Int64 ms), `payload` (`CKAsset`).
- Drive file name `slot-<slotId>.json.gz`, `appProperties` `slotId` and `deviceName`, `spaces=appDataFolder`.
- Cloud slot bodies are #1414's `BackupPayload` (version stays 1) with one optional top-level field `movedTo` (`relay` | `icloud` | `gdrive`). Cloud stores never carry `GroupBackupRecord`s.
- Slot limit 4194304 bytes on every store (`BackupSyncService.maxSlotBytes`).
- Not on web: every new provider returns its "unavailable" variant when `kIsWeb`.
- iCloud only on iOS and macOS. Google Drive on Android, Android TV, iOS, macOS, Linux, Windows.
- All user-visible text goes through ARB (`lib/l10n/app_en.arb`); no em dashes in copy or docs.
- Fictional media names only in tests.
- Commits: `git commit -F <msgfile>` with direnv loaded; `git show --stat` after each.

## Review Focus

1. **Refactor regression in the relay path.** A 1414 behaviour (CAS retry on 412/409, re-upload after rotation, recovery key reconcile, removals) silently lost while moving code into the engine and transport. Expected: every 1414 test passes with its assertions unchanged. Pinned by Task 3 Step 4 (full `test/core/backup` and `test/presentation/screens/backup` runs, before and after).
2. **Google refresh token revoked from the Google account page while the app runs.** Expected: one refresh attempt, status "Signed out" with Reconnect, no local data cleared, no retry loop. Test in Task 6 (`refresh_invalid_grant_reports_signed_out`) and Task 5 (`signed_out_halts_without_clearing`).
3. **Two devices switch stores in opposite directions at the same time** (A relay to gdrive, B gdrive to relay). Expected: each sees the other's `movedTo` stub and a Switch prompt; neither loops or deletes the other's data. Test in Task 5 (`crossed_switch_shows_prompt_both_ways`).
4. **A slot from a newer build** (`v: 2`) in a cloud store. Expected: that slot skipped, the rest merged, "A device uses a newer Mydia" shown. Test in Task 4 (`newer_version_slot_is_flagged_not_merged`).
5. **iCloud account signed out or switched to another Apple ID while backing up.** Expected: status "iCloud unavailable"; on a different account, the cached change token and own record state are dropped and a full list runs. Test in Task 8 (`account_change_resets_token`).

---

### Task 0: Device-code probe and spec touch-ups

Needs a human: a Google Cloud project with a "TVs and Limited Input devices" OAuth client. Ask the user for it if `MYDIA_GDRIVE_CLIENT_ID_TV` is not available.

**Files:**
- Create: `player/tool/gdrive_device_probe.dart`
- Modify: `design/specs/2026-11-14-player-cloud-drive-backup-design.md`

- [ ] **Step 1: Write the probe.** A `dart run` script that POSTs `client_id` and `scope=https://www.googleapis.com/auth/drive.appdata` to `https://oauth2.googleapis.com/device/code` and prints the status and body.
- [ ] **Step 2: Run it.** `cd player && dart run tool/gdrive_device_probe.dart <client_id>`. 200 with a `user_code` means the scope is allowed; `invalid_scope` means it is not.
- [ ] **Step 3: Record the answer in the spec's Google Drive "Open risk" paragraph**, replacing it with the result. If refused, stop and ask the user before Task 6's TV part: the fallback (phone hands its refresh token and client id over p2p) becomes Task 6b.
- [ ] **Step 4: Spec touch-ups that the code shape forces.** In the spec's Architecture table:
  - `RelayBackupService` becomes "`BackupSyncService` keeps its name", so 1414's fakes and screens keep compiling.
  - In the iCloud section, the plugin becomes a `CloudKitPlugin.swift` handler in each Runner target (the `NativeTabBarPlugin.swift` pattern), not a package.
  - The `schema` header is #1414's `BackupPayload.version`, with `movedTo` as an optional field.
- [ ] **Step 5: Commit** `docs(design): device-code probe result and spec touch-ups` with the probe script.

### Task 1: SlotTransport interface and contract suite

**Files:**
- Create: `player/lib/core/backup/slot_transport.dart`
- Create: `player/test/core/backup/in_memory_slot_transport.dart`
- Create: `player/test/core/backup/slot_transport_contract.dart`
- Create: `player/test/core/backup/in_memory_slot_transport_test.dart`

**Interfaces:**
- Produces:
```dart
class SlotInfo {
  const SlotInfo({required this.slotId, required this.version,
      this.deviceName, this.updatedAtMs, this.size});
  final String slotId;
  final String version;          // opaque; changes on every write
  final String? deviceName;
  final int? updatedAtMs;
  final int? size;
}

class SlotListing {
  const SlotListing({required this.cursor, required this.slots,
      this.ownStale = false});
  final String? cursor;          // pass back to list(); null = never conditional
  final List<SlotInfo> slots;    // includes this device's own slot when present
  final bool ownStale;           // engine must force an upload (relay: own epoch < vault epoch)
}

abstract class SlotTransport {
  String get ownSlotId;
  Future<SlotListing?> list({String? cursor});   // null = unchanged since cursor
  Future<BackupPayload> read(SlotInfo slot);     // throws FormatException when undecodable
  Future<void> writeOwn(BackupPayload payload);  // throws BackupRelayException(tooLarge) over 4194304 bytes
  Future<void> delete(String slotId);
  Stream<void> get changes;
}
```
- `InMemorySlotTransport` (test): a shared `Map<String, List<int>>` "server" so two transports with different `ownSlotId`s see each other; a `failNext(BackupRelayException)` hook; `pushChange()` emits on `changes`.
- `void runSlotTransportContract(String name, Future<(SlotTransport a, SlotTransport b)> Function() make)`: the shared suite reused by Tasks 2, 7 and 8.

- [ ] **Step 1: Write the contract tests** in `slot_transport_contract.dart`:
  - `own_write_is_listed_with_device_name`
  - `version_changes_on_rewrite`
  - `list_with_current_cursor_returns_null`
  - `other_device_write_makes_list_non_null`
  - `read_roundtrips_payload` (records, deviceName, platform equal)
  - `delete_removes_from_listing`
  - `oversize_write_throws_tooLarge` (4194305-byte payload after encoding; use random incompressible bytes in a setting record)
- [ ] **Step 2: Run** `./dev flutter test --concurrency=1 test/core/backup/in_memory_slot_transport_test.dart`. Expected: FAIL (types missing).
- [ ] **Step 3: Implement** `slot_transport.dart` and the in-memory fake.
- [ ] **Step 4: Run again.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): SlotTransport interface and contract suite`.

### Task 2: RelaySlotTransport

Moves the relay I/O and vault-state bookkeeping out of `BackupSyncService` without changing behaviour.

**Files:**
- Create: `player/lib/core/backup/relay_slot_transport.dart`
- Create: `player/test/core/backup/relay_slot_transport_test.dart`

**Interfaces:**
- Consumes: `SlotTransport`, `SlotInfo`, `SlotListing` (Task 1); `BackupRelayClient`, `BackupVaultOps`, `VaultCrypto`, `BackupVaultStateStore`, `BackupIdentity`, `BackupManifest` (#1414).
- Produces:
```dart
class RelaySlotTransport implements SlotTransport {
  RelaySlotTransport({required BackupRelayClient relay,
      required BackupVaultStateStore store, required BackupIdentity identity,
      required BackupVaultState state, required int Function() nowMs});
  BackupVaultState get state;                       // current, saved after every change
  BackupManifest? get lastManifest;                 // from the last non-null list()
  Stream<BackupManifest> get manifests;             // every manifest read, before epoch adoption
  Future<BackupVaultState> Function(BackupManifest)? beforeAdopt; // service hook: recovery reconcile
}
```
- `list` is `manifest(etag: cursor)`, then `beforeAdopt`, then epoch adoption (moved `_adoptEpoch`), with own-seq catch-up.
  - Each `SlotInfo.version` is `'${seq}'`; `cursor` is the manifest ETag.
  - `ownStale` is own `epoch < m.epoch`.
- `writeOwn` seals (moved `_upload` inner loop) with the one-retry rule on `preconditionFailed`/`conflict`.
- `read` is `BackupVaultOps.readSlot`; a null result throws `FormatException`.

- [ ] **Step 1: Write tests** against `test/core/backup/fake_backup_relay.dart`:
  - call `runSlotTransportContract('relay', ...)` with two members of one vault;
  - `write_retries_once_on_412_then_succeeds`;
  - `write_adopts_new_epoch_on_409`;
  - `list_sets_ownStale_after_rotation`;
  - `beforeAdopt_runs_before_epoch_adoption`.
- [ ] **Step 2: Run** `./dev flutter test --concurrency=1 test/core/backup/relay_slot_transport_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** by moving code, not copying. `BackupSyncService` is not edited yet, so the logic temporarily exists twice until Task 3.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): relay slot transport`.

### Task 3: SlotSyncEngine extraction

**Files:**
- Create: `player/lib/core/backup/slot_sync_engine.dart`
- Modify: `player/lib/core/backup/backup_sync_service.dart` (delegate upload, poll, apply, timers, backoff and offers to the engine; delete the duplicated relay I/O now in `RelaySlotTransport`)
- Create: `player/test/core/backup/slot_sync_engine_test.dart`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces:
```dart
class SlotSyncEngine {
  SlotSyncEngine({required BackupMetaStore meta, required BackupSnapshot snapshot,
      required Future<String> Function() deviceName, required String platform,
      required DateTime Function() clock,
      Future<void> Function(Map<String, BackupPayload>)? beforeApply, // relay: slot claims
      List<BackupRecord> Function(List<BackupRecord>)? filterOwn});   // cloud: drop GroupBackupRecord
  static const debounce = Duration(minutes: 2);
  static const pollInterval = Duration(minutes: 15);
  static const maxBackoff = Duration(minutes: 30);

  void attach(SlotTransport t, {int? lastSuccessMs});  // starts polling and listens to t.changes
  Future<void> detach();                               // stops timers, keeps meta
  ValueListenable<BackupStatus> get status;
  ValueListenable<Set<String>> get unreadableSlots;
  ValueListenable<bool> get newerVersionSeen;          // Task 4 fills it
  ValueListenable<List<PendingAccountOffer>> get pendingOffers;
  ValueListenable<List<SlotInfo>> get slots;           // last listing, own first
  void markDirty(); Future<void> flush(); Future<void> poll();
  Future<void> uploadNow({bool force = false});
  Future<Map<String, BackupPayload>> readAll(SlotTransport t);  // restore preview
  Future<ApplyResult> apply(Map<String, BackupPayload> p, BackupApplyMode mode);
  Future<void> acceptOffer(String accountId); Future<void> dismissOffer(String accountId);
  Future<T> serialise<T>(Future<T> Function() op);     // the one queue; services run member ops through it
  void reportFailure(BackupRelayError kind, [BackupRelayException? e]);
  void halt(); void setStatus(BackupStatus s);
}
```
- The merged-version bookkeeping moves from `mergedSeq` (int) to a string version. Add `BackupMetaStore.mergedVersion(slotId)` / `setMergedVersion` that read the old int seq as its string, so an upgraded install does not re-merge everything. `clearMergedSeqs` clears both.
- `BackupSyncService` keeps its public API byte for byte (the screens and `FakeBackupSyncService` must compile untouched). It:
  - owns a `SlotSyncEngine` and a `RelaySlotTransport` per joined vault;
  - forwards its listenables to the engine's;
  - subscribes to `manifests` for `_publishMembers` and `_reconcileRemovals`;
  - sets `beforeAdopt` to `_reconcileRecovery`;
  - runs member ops through `engine.serialise`.

- [ ] **Step 1: Record the baseline.** `./dev flutter test --concurrency=1 test/core/backup test/presentation/screens/backup test/core/p2p/peer_sync_backup_pairing_test.dart`, all passing on the unmodified branch.
- [ ] **Step 2: Write engine tests** on `InMemorySlotTransport`:
  - `debounce_coalesces_marks_into_one_upload`;
  - `unchanged_records_skip_upload_unless_forced`;
  - `ownStale_forces_upload_after_poll`;
  - `changes_stream_triggers_poll`;
  - `backoff_doubles_to_30_minutes` (fake clock);
  - `unreadable_slot_not_redownloaded_until_version_moves`;
  - `legacy_int_mergedSeq_read_as_version`.
- [ ] **Step 3: Implement** the engine, then rewire `BackupSyncService`.
- [ ] **Step 4: Run Step 1's command again.** Expected: the same tests pass with no assertion edited. A test that needs a change is a behaviour change: stop and fix the code instead. Then run the engine tests: PASS.
- [ ] **Step 5: Commit** `refactor(player): extract SlotSyncEngine from BackupSyncService`.

### Task 4: Payload `movedTo`, new error kinds and statuses

**Files:**
- Modify: `player/lib/core/backup/backup_records.dart` (`BackupPayload`)
- Modify: `player/lib/core/backup/backup_relay_client.dart` (`BackupRelayError`)
- Modify: `player/lib/core/backup/slot_sync_engine.dart`
- Modify: `player/test/core/backup/backup_records_test.dart`, `slot_sync_engine_test.dart`

**Interfaces:**
- Produces:
  - `BackupPayload.movedTo` (`String?`), encoded only when non-null.
  - A `NewerBackupVersionException extends FormatException`, thrown by `decode` when `v` is an int above 1.
  - `BackupRelayError` gains `signedOut`, `quotaFull`, `cloudUnavailable`.
  - The engine sets `newerVersionSeen` when a read throws `NewerBackupVersionException`.
  - A slot whose payload has `movedTo` is not merged; the engine exposes `ValueListenable<Map<String, String>> movedSlots` (slotId to store id).
  - `signedOut` and `cloudUnavailable` halt the engine like `unavailable` (no timer), with status `BackupError(kind, lastSuccessMs)`. `quotaFull` behaves like `tooLarge` (retry on the next change).

- [ ] **Step 1: Write tests:**
  - `movedTo_roundtrips_and_is_absent_when_null`;
  - `payload_with_unknown_top_level_field_decodes` (pins #1414 compatibility);
  - `newer_version_slot_is_flagged_not_merged`;
  - `moved_slot_is_listed_not_merged`;
  - `signed_out_halts_without_clearing` (local stores untouched, no retry timer);
  - `quota_full_waits_for_next_change`.
- [ ] **Step 2: Run** `./dev flutter test --concurrency=1 test/core/backup/backup_records_test.dart test/core/backup/slot_sync_engine_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS. Add `test/presentation/screens/backup` so status switches stay exhaustive.
- [ ] **Step 5: Commit** `feat(player): moved and newer-version slots, cloud error kinds`.

### Task 5: CloudSlotTransport and CloudBackupService

**Files:**
- Create: `player/lib/core/backup/cloud/cloud_backend.dart`
- Create: `player/lib/core/backup/cloud/cloud_slot_transport.dart`
- Create: `player/lib/core/backup/cloud/cloud_backup_service.dart`
- Create: `player/test/core/backup/cloud/in_memory_cloud_backend.dart`
- Create: `player/test/core/backup/cloud/cloud_slot_transport_test.dart`
- Create: `player/test/core/backup/cloud/cloud_backup_service_test.dart`

**Interfaces:**
- Consumes: Tasks 1, 3 and 4; `BackupIdentity.slotId`.
- Produces:
```dart
enum CloudStoreKind { icloud, gdrive }   // .name is the store id

abstract class CloudBackend {
  CloudStoreKind get kind;
  Future<CloudAvailability> availability();  // available(accountLabel) | signedOut | unavailable
  Future<CloudListing?> list({String? cursor});
  Future<List<int>> readBytes(String slotId);
  Future<void> writeBytes(String slotId, List<int> bytes,
      {required String deviceName, required String platform});
  Future<void> delete(String slotId);
  Stream<void> get changes;
  Future<void> signOut();                    // forget local credentials only
}
```
- `CloudListing` mirrors `SlotListing` without `ownStale`. Backends throw `BackupRelayException` with the Task 4 kinds.
- `CloudSlotTransport(CloudBackend, ownSlotId)` encodes and decodes `BackupPayload` and checks the 4 MB limit before `writeBytes`.
- `CloudBackupService(engine, backend, identity, meta)`:
  - `enable()` checks availability, then `engine.attach` and upload-then-full-poll.
  - `previewRestore()` reads all slots except own (and except `movedTo` stubs). It returns `CloudRestorePreview({required Map<String, BackupPayload> payloads, required Set<String> unreadableSlots})` with `records = lwwMerge(...)` as in #1414's `RestorePreview`, which is relay-shaped (vault key, manifest) and not reused. It throws `BackupRelayException(notFound)` when there are no slots.
  - `commitRestore(CloudRestorePreview)` applies in `BackupApplyMode.restore`, then enables.
  - `removeDevice(slotId)` calls `backend.delete`.
  - `switchAway(String to, {required bool deleteOld})` writes the own stub `{movedTo: to, records: []}`, then either deletes every slot or keeps them, and detaches.
  - `disable()` detaches and signs out.
  - `deleteBackup()` deletes all slots, then `disable()`.
  - The engine gets `filterOwn` dropping `GroupBackupRecord`.

- [ ] **Step 1: Write tests:**
  - `runSlotTransportContract('cloud', ...)` over `InMemoryCloudBackend`;
  - `group_records_never_written_to_cloud`;
  - `restore_on_empty_store_throws_notFound`;
  - `restore_applies_accounts_and_settings_then_joins`;
  - `live_join_offers_accounts_not_applies` (mirror #1414's offer test);
  - `remove_device_deletes_slot_and_it_reappears_on_its_next_upload`;
  - `switch_away_leaves_stub_and_other_device_sees_moved`;
  - `crossed_switch_shows_prompt_both_ways`.
- [ ] **Step 2: Run** `./dev flutter test --concurrency=1 test/core/backup/cloud`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): cloud slot transport and service`.

### Task 6: Google sign-in

**Files:**
- Modify: `player/pubspec.yaml` (add `google_sign_in: ^7.2.0`); Android and iOS config per that package's README (iOS `GIDClientID` and the reversed-client-id URL scheme in `ios/Runner/Info.plist`, from `--dart-define` via xcconfig)
- Create: `player/lib/core/backup/cloud/google_auth.dart`
- Create: `player/lib/core/backup/cloud/google_oauth_flows.dart`
- Create: `player/test/core/backup/cloud/google_auth_test.dart`

**Interfaces:**
- Produces:
```dart
abstract class GoogleAuth {
  Future<String?> currentEmail();
  Future<String> accessToken({bool forceRefresh = false}); // throws BackupRelayException(signedOut)
  Future<void> signOut();
}
class GoogleSignInAuth implements GoogleAuth { ... }       // Android phones, iOS
class GoogleTokenAuth implements GoogleAuth {              // desktop and TV
  GoogleTokenAuth({required AuthStorage storage, required http.Client client,
      required String clientId, required String clientSecret});
}
class LoopbackPkceFlow {                                    // macOS, Linux, Windows
  Future<void> signIn(GoogleTokenAuth auth,
      {Future<bool> Function(Uri) launch = launchUrl});
}
class DeviceCodeFlow {                                      // Android TV
  Stream<DeviceCodeState> signIn(GoogleTokenAuth auth);
}
sealed class DeviceCodeState { }  // Code(userCode, verificationUrl, expiresAt) | Done | Denied | Expired
GoogleAuth? googleAuthForPlatform(AuthStorage s);           // null when the define for this platform is empty
```
- Endpoints:
  - auth: `https://accounts.google.com/o/oauth2/v2/auth`
  - token: `https://oauth2.googleapis.com/token`
  - device: `https://oauth2.googleapis.com/device/code`
  - revoke: `https://oauth2.googleapis.com/revoke`
- PKCE is S256, with the verifier 64 random bytes base64url-encoded without padding.
- The loopback server binds `127.0.0.1` on port 0 and has a 5-minute timeout.
- Device-code polling honours `interval`, adds 5 s on `slow_down`, and stops at `expires_in`.
- Email comes from the `id_token` in the token response (request the `openid email` scopes alongside `drive.appdata` for this purpose only).
- Platform choice:
  - `InputCapabilities.directionalPrimary` on Android picks `DeviceCodeFlow`;
  - Android and iOS otherwise pick `GoogleSignInAuth`;
  - macOS, Linux and Windows pick `LoopbackPkceFlow`.

- [ ] **Step 1: Write tests** against a `MockClient` token endpoint:
  - `pkce_challenge_is_s256_of_verifier`;
  - `loopback_exchanges_code_and_stores_refresh_token`;
  - `loopback_rejects_mismatched_state`;
  - `device_code_pending_then_done`;
  - `device_code_slow_down_adds_5s`;
  - `device_code_expired_and_denied`;
  - `refresh_invalid_grant_reports_signed_out` (clears `backup/gdrive`, throws `signedOut`);
  - `access_token_cached_until_expiry`.
- [ ] **Step 2: Run** `./dev flutter test --concurrency=1 test/core/backup/cloud/google_auth_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** Wrap `GoogleSignInAuth` thinly around `GoogleSignIn.instance.authorizationClient.authorizeScopes`; no unit test beyond a compile check.
- [ ] **Step 4: Run.** Expected: PASS. Then `./dev flutter analyze`: clean.
- [ ] **Step 5: Commit** `feat(player): Google sign-in for Drive backup`.

### Task 7: GoogleDriveBackend

**Files:**
- Create: `player/lib/core/backup/cloud/google_drive_backend.dart`
- Create: `player/test/core/backup/cloud/fake_drive_server.dart`
- Create: `player/test/core/backup/cloud/google_drive_backend_test.dart`

**Interfaces:**
- Consumes: `CloudBackend` (Task 5), `GoogleAuth` (Task 6).
- Produces: `GoogleDriveBackend({required GoogleAuth auth, required http.Client client, required BackupMetaStore meta})`.
  - `list` is `GET https://www.googleapis.com/drive/v3/files?spaces=appDataFolder&fields=files(id,name,version,modifiedTime,size,appProperties)&pageSize=100`, paged by `nextPageToken`.
    - The cursor is `sha256` over sorted `name:version` pairs; equal means `null`.
    - `SlotInfo.version` is Drive's `version`.
  - `writeBytes`:
    - with no cached id: `POST https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart` with metadata `{name, parents:["appDataFolder"], appProperties}`;
    - otherwise: `PATCH .../files/<id>?uploadType=multipart`.
    - The own file id is cached in `BackupMetaStore` under a new key `gdriveOwnFileId`; a 404 on PATCH clears it and creates.
  - `readBytes` is `GET .../files/<id>?alt=media`.
  - `availability` is `currentEmail()`.
- Error mapping:

  | Response | Kind |
  | --- | --- |
  | 401 | retry once with `forceRefresh`, then `signedOut` |
  | 403 `storageQuotaExceeded` | `quotaFull` |
  | 403 `rateLimitExceeded`/`userRateLimitExceeded` or 429 | `rateLimited` with `Retry-After` |
  | 5xx | `server` |
  | socket or timeout | `network` |
  | 404 on read | `FormatException` (the slot vanished between list and read) |

- [ ] **Step 1: Write tests:**
  - `runSlotTransportContract('gdrive', ...)` through `CloudSlotTransport` over two backends sharing one `FakeDriveServer`;
  - `first_write_creates_then_patches`;
  - `patch_404_recreates`;
  - `paged_listing_is_merged`;
  - `401_refreshes_once_then_signed_out`;
  - `quota_exceeded_maps_to_quotaFull`;
  - `rate_limit_carries_retry_after`.

  The fake asserts real request shapes: multipart boundary, `spaces`, `fields`, the `Authorization: Bearer` header.
- [ ] **Step 2: Run** `./dev flutter test --concurrency=1 test/core/backup/cloud/google_drive_backend_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): Google Drive backup backend`.

### Task 8: CloudKit backend

**Files:**
- Create: `player/ios/Runner/CloudKitPlugin.swift`, `player/macos/Runner/CloudKitPlugin.swift` (same source; macOS imports `FlutterMacOS`)
- Modify: `player/ios/Runner/AppDelegate.swift`, `player/macos/Runner/AppDelegate.swift` (register the plugin, `registerForRemoteNotifications`, forward silent pushes)
- Create: `player/ios/Runner/Runner.entitlements`. Set `CODE_SIGN_ENTITLEMENTS` in `ios/Runner.xcodeproj/project.pbxproj` for every Runner config. Add `com.apple.developer.icloud-container-identifiers`, `com.apple.developer.icloud-services` (`CloudKit`) and `aps-environment` to it and to `macos/Runner/DebugProfile.entitlements` and `Release.entitlements`
- Create: `player/ios/RunnerTests/CloudKitPluginTests.swift`
- Create: `player/lib/core/backup/cloud/cloudkit_backend.dart`
- Create: `player/test/core/backup/cloud/cloudkit_backend_test.dart`
- Modify: `player/docs/packaging.md` (the macOS Developer ID profile needs iCloud; the container must exist in the Apple developer account)

**Interfaces:**
- Channel `mydia/cloudkit` methods (arguments and results are plain maps):

  | Method | Arguments | Result |
  | --- | --- | --- |
  | `accountStatus` | none | `available`, `noAccount`, `restricted` or `temporarilyUnavailable`, plus `userRecordName` when available |
  | `fetchChanges` | `{token: String?}` (base64 archived `CKServerChangeToken`) | `{records: [{slotId, deviceName, platform, updatedAt, size, tag}], deleted: [slotId], token}` |
  | `fetchPayload` | `{slotId}` | `Uint8List` |
  | `save` | `{slotId, deviceName, platform, bytes}` | none |
  | `delete` | `{slotId}` | none |
  | `subscribe` | none | none |

  - `fetchChanges` creates the zone when missing and loops `moreComing` inside Swift.
  - `save` uses `.allKeys` save policy, so it overwrites.
  - `subscribe` is idempotent; the subscription id is `backup-changes`.
  - Errors are `FlutterError` codes `notAuthenticated`, `unavailable`, `quotaExceeded`, `zoneNotFound`, `changeTokenExpired`, `network`, `other`.
- EventChannel `mydia/cloudkit/changes` emits on each silent push and on `CKAccountChanged`.
- `CloudKitBackend({MethodChannel? channel, EventChannel? events, required BackupMetaStore meta})`:
  - Keeps the change token and a local slot table in `BackupMetaStore` keys `cloudkitToken`, `cloudkitSlots` (JSON) and `cloudkitUser`.
  - Builds `SlotInfo.version` from the record `tag`; the cursor is the token.
  - `changeTokenExpired` or `zoneNotFound` clears the token and table, then refetches once.
  - A different `userRecordName` from `accountStatus` than the stored one clears the token, table and `cloudkitUser` first.
  - Codes map to kinds: `notAuthenticated` and `unavailable` become `cloudUnavailable`; `quotaExceeded` becomes `quotaFull`; `network` becomes `server`.

- [ ] **Step 1: Write Dart tests** with `TestDefaultBinaryMessengerBinding` mocking the channel:
  - `runSlotTransportContract('icloud', ...)` (the fake holds records in a map shared by two backends);
  - `token_persisted_and_sent_back`;
  - `expired_token_refetches_once`;
  - `deleted_ids_drop_from_listing`;
  - `account_change_resets_token`;
  - `not_authenticated_maps_to_cloudUnavailable`.
- [ ] **Step 2: Write XCTests** for the pure helpers in `CloudKitPlugin.swift`:
  - `testRecordToMapCarriesAllFields`;
  - `testErrorCodeMapping` (`CKError.notAuthenticated` to `notAuthenticated`, `.quotaExceeded`, `.changeTokenExpired`, `.zoneNotFound`, `.networkUnavailable` to `network`);
  - `testTokenArchiveRoundTrip`.
- [ ] **Step 3: Run** `./dev flutter test --concurrency=1 test/core/backup/cloud/cloudkit_backend_test.dart`. Expected: FAIL.
- [ ] **Step 4: Implement** the Dart backend and the Swift handler.
- [ ] **Step 5: Run** the Dart tests: PASS. On the Mac, `./dev player macos build` succeeds and the iOS XCTests pass from Xcode (`RunnerTests`). If no Mac is reachable this session, say so in the PR and leave it for Task 11's manual pass.
- [ ] **Step 6: Commit** `feat(player): CloudKit backup backend`.

### Task 9: BackupController, providers, lifecycle and pairing hint

**Files:**
- Create: `player/lib/core/backup/backup_controller.dart`
- Modify: `player/lib/core/backup/backup_providers.dart`, `player/lib/app.dart` (lifecycle calls go to the controller), `player/lib/presentation/screens/connections/pair_device_sheet.dart`
- Modify: `native/mydia_p2p_core/src/peer_sync.rs` (`Paired` gains `#[serde(default)] backup_store: Option<String>` and `backup_account: Option<String>`), `player/rust/mydia_player_p2p/src/lib.rs`; regenerate the bridge (`player/lib/native/*`, `frb_generated.rs`) per `player/docs/workflow.md`
- Modify: `player/lib/core/p2p/peer_sync_service.dart`, `BackupPairingHooks` (a `cloudStoreForPair` hook and an `onCloudStoreHint` hook)
- Create: `player/test/core/backup/backup_controller_test.dart`; Rust test in `peer_sync.rs` for old-shape `Paired` decode

**Interfaces:**
- Consumes: `BackupSyncService` (Task 3), `CloudBackupService` (Task 5), the backends (Tasks 7 and 8).
- Produces:
```dart
enum BackupStoreKind { relay, icloud, gdrive }
class BackupController {
  ValueListenable<BackupStoreKind?> get active;      // null = off
  ValueListenable<CloudStoreHint?> get storeHint;    // from pairing: kind + account label
  Set<BackupStoreKind> get offered;                  // per platform, per define
  BackupSyncService get relay;                       // unchanged #1414 service
  CloudBackupService cloud(BackupStoreKind kind);
  Future<void> enableCloud(BackupStoreKind kind);    // requires a signed-in backend
  Future<void> switchTo(BackupStoreKind to, {required bool deleteOld});
  void markDirty(); Future<void> flush(); Future<void> poll();
  void acknowledgeHint();
}
final backupControllerProvider = Provider<BackupController>(...);
```
- `active` reads `backup/store`. A missing key with a relay vault in `backup/vault` means `relay`, so #1414 installs migrate. The controller writes the key on every change.
- `backupSyncServiceProvider` stays and is used for the relay. All triggers in `backupSyncServiceProvider` (Hive watch, sources, settings, p2p state) move to the controller, which forwards them to the active service.
- Pairing:
  - When the store is `icloud` or `gdrive`, `Paired` carries `backup_store` and `backup_account` (the Google email, or null for iCloud) and no `vault_id`.
  - The joiner stores it as `storeHint` and does nothing else.
  - With `relay`, #1414's hooks run unchanged.
- `offered`:
  - `icloud` only on iOS and macOS;
  - `gdrive` when `googleAuthForPlatform` is non-null;
  - `relay` everywhere native;
  - nothing on web.

- [ ] **Step 1: Write tests:**
  - `install_with_relay_vault_and_no_store_key_is_relay`;
  - `switch_relay_to_gdrive_writes_stub_and_key`;
  - `triggers_reach_only_active_service`;
  - `offered_excludes_icloud_off_apple`;
  - `paired_hint_sets_storeHint_without_joining`;
  - Rust `paired_without_backup_store_decodes`.
- [ ] **Step 2: Run** `./dev flutter test --concurrency=1 test/core/backup/backup_controller_test.dart test/core/p2p` and `cd native/mydia_p2p_core && cargo test`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run both.** Expected: PASS, including #1414's `peer_sync_backup_pairing_test.dart`.
- [ ] **Step 5: Commit** `feat(player): BackupController and the cloud store pairing hint`.

### Task 10: UI

**Files:**
- Create: `player/lib/presentation/screens/backup/store_picker.dart`
- Create: `player/lib/presentation/screens/backup/cloud_backup_body.dart`
- Create: `player/lib/presentation/screens/backup/google_device_code_sheet.dart`
- Modify: `player/lib/presentation/screens/connections/backup_section.dart` (off state shows the picker; enabled state shows the relay body or the cloud body; status lines; moved, hint and newer-version notices)
- Modify: `player/lib/presentation/screens/backup/restore_backup_screen.dart`:
  - three entries;
  - extract the preview body into a widget taking `List<BackupRecord> records` and `int unreadable`, shared by `RestorePreview` and `CloudRestorePreview`;
  - a cloud entry signs in if needed, then shows that widget.
- Modify: `player/lib/presentation/screens/login_screen.dart` (on iOS and macOS, a direct "Restore from iCloud" when `previewRestore` finds slots, probed once with a 5 s timeout)
- Modify: `player/lib/l10n/app_en.arb`
- Tests: `player/test/presentation/screens/backup/store_picker_test.dart`, `cloud_backup_body_test.dart`, `google_device_code_sheet_test.dart`; extend `backup_section_test.dart`, `restore_backup_screen_test.dart`, `backup_focus_tv_test.dart`; a `FakeBackupController` beside `fake_backup_sync_service.dart`

**Copy** (ARB values, exact):

| Key | Value |
| --- | --- |
| `backupStoreRelay` | `Mydia relay (end-to-end encrypted)` |
| `backupStoreICloud` | `iCloud` |
| `backupStoreGoogleDrive` | `Google Drive` |
| `backupStoreICloudPrivacy` | `Stored in your iCloud account. Apple can read it, including your source sign-ins.` |
| `backupStoreGoogleDrivePrivacy` | `Stored in your Google account. Google can read it, including your source sign-ins.` |
| `backupStoreRelayPrivacy` | `Only your devices can read it. Keep the recovery key safe.` |
| `backupCloudActive` | `Backing up to {store} ({account})` |
| `backupCloudActiveNoAccount` | `Backing up to {store}` |
| `backupSignedOut` | `Signed out of {store}. Backup is paused.` / action `backupReconnect`: `Reconnect` |
| `backupQuotaFull` | `Your Google storage is full. Backup is paused.` |
| `backupICloudUnavailable` | `iCloud is unavailable. Sign in to iCloud in Settings.` |
| `backupNewerVersion` | `A device uses a newer Mydia. Update this one to read its backup.` |
| `backupMovedNotice` | `{device} moved backup to {store}.` / action `backupSwitch`: `Switch` |
| `backupStoreHint` | `Your devices back up to {store}. Sign in to join.` |
| `backupSwitchConfirm` | `Switch backup to {store}? Your other devices will be asked to switch too.` |
| `backupSwitchDeleteOld` | `Delete the backup in {store}` |
| `backupRemoveCloudDeviceConfirm` | `Remove {device} from the backup? It can still read the backup until it signs out of {store}.` |
| `restoreFromICloud` | `Restore from iCloud` |
| `restoreFromGoogleDrive` | `Restore from Google Drive` |
| `restoreWithRecoveryKey` | `Restore with a recovery key` |
| `googleDeviceCodeTitle` | `Sign in to Google` |
| `googleDeviceCodeBody` | `On your phone, open {url} and enter this code:` |
| `googleDeviceCodeExpired` | `The code expired. Try again.` |

Removal on Drive also shows a link to `https://myaccount.google.com/connections`.

- [ ] **Step 1: Write widget tests:**
  - `picker_lists_offered_stores_with_privacy_lines`;
  - `picking_gdrive_runs_sign_in_then_enables`;
  - `cloud_body_shows_account_and_devices_without_recovery_key`;
  - `signed_out_shows_reconnect`;
  - `moved_notice_switch_calls_switchTo`;
  - `hint_notice_shown_until_acknowledged`;
  - `restore_screen_shows_three_entries_on_apple_two_elsewhere`;
  - `login_offers_icloud_restore_when_slots_exist`;
  - `device_code_sheet_shows_code_and_qr_and_expiry`;
  - TV: `picker_and_device_code_sheet_reachable_by_dpad`.
- [ ] **Step 2: Run** `./dev flutter test --concurrency=1 test/presentation/screens/backup test/presentation/screens/connections`. Expected: new tests FAIL.
- [ ] **Step 3: Implement**, then `./dev flutter gen-l10n` (or the project's l10n step per `player/docs/l10n.md`).
- [ ] **Step 4: Run.** Expected: PASS. `./dev flutter analyze` is clean.
- [ ] **Step 5: Commit** `feat(player): store picker, cloud backup screens and restore entries`.

### Task 11: Docs, full verification, manual pass

**Files:**
- Modify: `player/lib/core/backup/README.md` (stores, units table with the new files, where state lives: `backup/store`, `backup/gdrive`, the new meta keys)
- Modify: `design/specs/2026-11-14-player-cloud-drive-backup-design.md` only if implementation diverged

- [ ] **Step 1: Update the README.**
- [ ] **Step 2: Full suite** using the wrapper `./dev player test` (which bundles concurrency=1 cleanly; or in chunks with `./dev flutter test --concurrency=1 test/core`, `test/presentation`, etc.). Expected: all pass, except flakes already catalogued in `.github/ci-flakes.md`.
- [ ] **Step 3:** `./dev flutter analyze`, `cargo test -p mydia_p2p_core`, `./dev mix precommit`. Expected: clean.
- [ ] **Step 4: Manual, with a real Google account and real client ids:**
  - enable on Linux;
  - restore on Android TV via device code;
  - live-join on iOS (offers appear);
  - revoke the app at myaccount.google.com and see "Signed out" on each.
- [ ] **Step 5: Manual iCloud on the Mac:**
  - enable on the macOS app and on the iOS simulator signed in to one Apple ID;
  - change a watch state on one and see it on the other within a minute (push);
  - sign out of iCloud and see "iCloud unavailable".
- [ ] **Step 6:** `git diff --name-only origin/feat/player-cloud-backup...` lists only files this plan names. Commit `docs(player): cloud drive backup README`, then push `HEAD:feat/player-cloud-drive-backup`.
