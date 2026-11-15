# iCloud and Google Drive as backup stores for the player

Builds on `design/specs/2026-11-14-player-cloud-backup-design.md` (PR #1414),
which stores an end-to-end encrypted vault on metadata-relay. That spec
rejected the user's own cloud as a store; this one adds it as an alternative,
for people who want what Infuse does: sign in to the same account on a new
device and everything is back, with no recovery key to keep.

## Goal

- A device group backs up to exactly one store: the Mydia relay (#1414's E2E
  vault), iCloud, or Google Drive.
- With iCloud or Google Drive, the cloud account is the group. Signing in to
  it on a fresh install restores, and a live device that signs in joins.
- Everything #1414 syncs and restores (watch state, pins, accounts with their
  tokens, the settings allowlist) travels the same way and under the same
  live/restore rules.

## Decisions

| Question | Decision |
| --- | --- |
| Use of the cloud | Backup and sync storage only. Cloud drives as media sources are out of scope |
| Encryption on cloud stores | None. The provider is trusted: slots are plaintext gzip JSON in the app's private area, and the UI says Apple or Google can read them, source sign-ins included |
| Relation to the relay vault | One store per group, chosen in Backup & sync. Switching is explicit |
| Providers and platforms | iCloud on iOS and macOS. Google Drive on Android, Android TV, iOS, macOS, Linux and Windows. Web: neither |
| iCloud API | CloudKit private database through a small Swift plugin, with a silent-push subscription |
| Google Drive API | Drive v3 `appDataFolder` with the `drive.appdata` scope only |
| Group membership on cloud stores | Whoever is signed in to the account. No pairing needed, no member list, no recovery key |

### Rejected

- **E2E on cloud stores with the vault key in iCloud Keychain / Block Store.**
  Keeps the relay's privacy, but Linux and Windows have no synced keychain and
  would still need the recovery key, so the "just sign in" promise holds only
  on some platforms. The user chose to trust the provider instead.
- **iCloud Drive files (ubiquity container) instead of CloudKit.** Gives both
  providers file semantics, but sync timing is opaque, files can be
  undownloaded placeholders, and there is no change push.
- **Emulating the relay protocol (manifest, members, epochs) on cloud files.**
  Carries crypto and membership machinery that plaintext storage makes
  pointless.
- **Writing to the relay and a cloud drive at once.** Doubles the sync paths
  and failure states for no user-visible gain.
- **`NSUbiquitousKeyValueStore`.** 1 MB total, below the 4 MB slot limit.

## Architecture

`BackupSyncService` from #1414 mixes a generic slot-sync loop with
relay-only features. It is split:

| Unit | Job |
| --- | --- |
| `slot_sync_engine.dart` (`SlotSyncEngine`) | Extracted from `BackupSyncService`: dirty flag and 2-minute debounce, flush on background, polling (foreground, after a p2p sync, every 15 minutes) and backoff to 30 minutes, downloading only slots whose version moved, `_apply` and merge, pending account offers, device names. Talks only to a `SlotTransport` |
| `slot_transport.dart` | The interface below, plus `SlotListing` and `SlotInfo`. Errors reuse #1414's `BackupRelayError` kinds |
| `relay_slot_transport.dart` | The relay client plus `VaultCrypto` sealing and opening, behind `SlotTransport` |
| `backup_sync_service.dart` (`BackupSyncService` keeps its name) | What remains of it: vault creation, recovery key, rotation, member removal, adding a member on pairing, vault choice. Owns an engine over `RelaySlotTransport`. Behaviour identical to #1414, and the name stays so 1414's fakes and screens keep compiling |
| `cloud/cloud_slot_transport.dart` | `SlotTransport` over a `CloudBackend`. Plaintext gzip JSON |
| `cloud/google_drive_backend.dart` | Drive v3 REST against `appDataFolder` |
| `cloud/google_auth.dart` | Sign-in per platform and token refresh |
| `cloud/cloudkit_backend.dart` | Dart side of the `mydia/cloudkit` channel handled by `CloudKitPlugin.swift` |
| `backup_controller.dart` (`BackupController`) | Holds the active store (`relay`, `icloud`, `gdrive`) in `AuthStorage` `backup/store`, starts the matching service, and is the only thing the UI talks to |

```dart
abstract class SlotTransport {
  String get ownSlotId;

  /// Null when nothing changed since [cursor].
  Future<SlotListing?> list({String? cursor});
  Future<BackupPayload> read(SlotInfo slot);
  Future<void> writeOwn(BackupPayload payload);
  Future<void> delete(String slotId);

  /// Hint that [list] would now return something. Empty for the relay and
  /// Drive; CloudKit pushes.
  Stream<void> get changes;
}
```

`SlotListing` carries an opaque `cursor` (the relay's manifest ETag, Drive's
newest `modifiedTime` plus file versions, CloudKit's server change token), the
list of `SlotInfo` and an `ownStale` flag the relay sets when this device's
epoch is behind the vault's. Each `SlotInfo` holds the slot id, an opaque
version, and optionally the device name, update time and size. The engine
keeps the version of each slot it has merged per store, so two stores that
happen to produce the same version string never mask each other.

The slot id on every store is #1414's per-install id from `BackupIdentity`,
so switching stores keeps a device's identity. A cloud slot's body is the
#1414 record list wrapped in a header: `schema` (#1414's
`BackupPayload.version`), `slotId`, `deviceName`, `platform`, `writtenAt`, and
an optional `movedTo` (see Switching).

## Google Drive

- **Scope**: `https://www.googleapis.com/auth/drive.appdata`, recommended and
  non-sensitive, so the OAuth app needs basic verification only. The app sees
  only its own hidden folder, never the user's files.
- **Sign-in**:

  | Platform | Flow |
  | --- | --- |
  | Android, iOS | `google_sign_in` |
  | macOS, Linux, Windows | System browser, loopback redirect, PKCE |
  | Android TV | Device-code flow: a code and a QR on screen, approved on a phone |

  The refresh token and account email live in `AuthStorage` `backup/gdrive`.
- **Open risk**: Google's limited-input flow accepts only an allowlist of
  scopes, and it is unconfirmed that `drive.appdata` is on it. The probe
  script at `player/tool/gdrive_device_probe.dart` posts the scope to the
  device-code endpoint and must be run with the TV client id before release.
  If the scope is refused, Android TV signs in by handing off from a paired
  phone: the phone sends its Drive refresh token and its (public) client id
  over the encrypted p2p channel, and the TV refreshes with them. Revoking
  either device's access
  then revokes both, which the TV's status row says.
- **Layout**: one file per device, `slot-<slotId>.json.gz`, with
  `appProperties` `slotId` and `deviceName`. `list` is
  `files.list(spaces=appDataFolder, fields=id,name,version,modifiedTime,size,appProperties)`.
  File names are `slot-<slotId>.json.gz`. `writeOwn` is a multipart
  `files.update`, or `files.create` the first time; the own file id is cached
  in `backup_meta`, and when it is missing the file is looked up by its own
  name before a create, so a lost cache never leaves two files. Freshness is
  #1414's polling.
- **Client ids**: one OAuth client per platform in a Mydia-owned Google Cloud
  project. They are public identifiers, compiled in through `--dart-define`;
  the relay is not involved.

## iCloud

- **Plugin**: a `CloudKitPlugin.swift` handler in each Runner target (iOS and
  macOS), the `NativeTabBarPlugin.swift` pattern, not a package. Each Runner
  carries its own copy of the handler. It exposes a
  MethodChannel plus an EventChannel for change pushes. Container
  `iCloud.dev.mydia.player`, private database, custom zone `Backup`.
- **Records**: type `Slot`, record name `slot-<slotId>`, fields `slotId`,
  `deviceName`, `platform`, `updatedAt`, `size`, `payload` (`CKAsset`, the gzip
  JSON).
- **Listing**: `CKFetchRecordZoneChangesOperation` with the stored server
  change token as the cursor.
- **Freshness**: a `CKDatabaseSubscription` with silent notifications; each
  push becomes an event on `changes`, which triggers a poll. Polling still
  runs as a fallback.
- **Availability**: no sign-in. `CKContainer.accountStatus` decides; without
  an account the option shows greyed with "Sign in to iCloud in Settings".
  `CKAccountChanged` re-checks.
- **Entitlements**: CloudKit and `aps-environment` on the iOS and macOS Runner
  targets, opt in per build: the build setting `MYDIA_CLOUDKIT` (`NO` by
  default) selects the entitlements file and is surfaced to the app as the
  Info.plist key `MydiaCloudKitEnabled`. A build without it never touches
  CloudKit and the app hides iCloud, so releases show no iCloud option until
  the signing setup (`player/docs/packaging.md`) is done. macOS needs a
  Developer ID provisioning profile with iCloud, which the release pipeline
  must gain. iCloud is never offered on Linux, Windows or Android.

## What a cloud store holds and excludes

Identical to #1414's "What the vault holds", with one consequence of
plaintext storage: the provider can read source tokens (Plex, Jellyfin, Stash,
WebDAV, SMB). Mydia server tokens stay excluded for #1414's reason: a copied
server token is a device the server cannot revoke on its own. The Group kind
(p2p group secret, node claims) is not written to cloud stores: membership is
the account, and the group secret has no business sitting in plaintext.

## Membership and removal

- Anyone signed in to the account is in the group.
- "Remove" on a device row deletes that device's slot. The confirmation says
  the device can still read the backup until it signs out, and links to
  Google's third-party access page (Drive) or says to sign out of iCloud on
  that device.
- A device whose own slot disappeared while it was signed in writes it again
  on its next upload. Removal is cleanup, not revocation.

## UX

- **Backup & sync** opens with a store picker: iCloud (Apple platforms only),
  Google Drive, Mydia relay (end-to-end encrypted). Each carries one line on
  privacy; the cloud ones read "Stored in your iCloud account. Apple can read
  it, including your source sign-ins" (Google's likewise).
- **Enabling a cloud store**: sign in if needed, upload this device's slot,
  merge the others, show "Backing up to Google Drive (a…@gmail.com)". No
  recovery key sheet.
- **Fresh install**: "Restore from backup" on the login screen offers
  iCloud, Google Drive, or a recovery key. On iOS and macOS, when CloudKit
  already holds slots, the login screen shows "Restore from iCloud" directly.
  Restore uses #1414's `RestorePreview` (counts of sources, watched items,
  pins; Apply or Cancel), applies accounts and settings, and joins the store.
- **Live device joining**: #1414's behaviour. Watch state and pins merge;
  accounts appear as "N sources added on {device}" offers.
- **Switching**: confirmed explicitly. The device rewrites its slot in the old
  store as a stub `{movedTo: "<store>"}`, offers to delete the old backup,
  then uploads to the new store. The new store is brought up before the old
  one is left, so a failed sign-in keeps the old store active. Deleting the
  old backup keeps this device's own moved stub, so other devices still learn
  where it went. Other devices reading the stub show
  "{device} moved backup to Google Drive" with a Switch button. Nothing
  migrates silently.
- **Pairing**: with the relay, #1414's add-member-on-pair is unchanged. With a
  cloud store, pairing sends only a hint (store kind, and the Google account
  email), so the new device shows "Your devices back up to Google Drive. Sign
  in to join". No token travels over p2p (the Android TV fallback above is
  the one exception, and only if the probe forces it).
- **Web**: hidden, as in #1414.

## Errors

On top of #1414's backoff:

| Condition | Behaviour |
| --- | --- |
| Drive 401 or `invalid_grant` | One refresh; if it fails, status "Signed out" with Reconnect. Syncing stops; local data is untouched |
| Drive 403 `storageQuotaExceeded` | Status "Google storage full". No retry until the next change or foreground |
| Drive 429 or 5xx | Backoff |
| CloudKit `notAuthenticated`, `accountTemporarilyUnavailable` | Status "iCloud unavailable"; `CKAccountChanged` re-checks |
| CloudKit network and rate-limit failures | Mapped to `network`: backoff, honouring the server's retry-after |
| A slot that vanishes while a restore preview reads it | Skipped; the preview covers the rest |
| CloudKit `zoneNotFound`, `changeTokenExpired` | Recreate the zone or drop the token, then a full list |
| CloudKit `serverRecordChanged` on the own slot | Overwrite: only this device writes it |
| Slot that fails to decode | Skipped and logged, as in #1414 |
| Slot with a newer `schema` | Skipped; status line "A device uses a newer Mydia" |

## Testing

- **Refactor safety**: #1414's suites (`backup_sync_service_test`,
  `fake_backup_relay`, the device rig, the screen tests) run unchanged in
  intent against `BackupSyncService` over `SlotSyncEngine` and
  `RelaySlotTransport`.
- **Transport contract**: one shared suite over `SlotTransport` run against
  an in-memory fake, `GoogleDriveBackend` on a `MockClient` fake Drive that
  replays real request shapes, and `CloudKitBackend` on a fake MethodChannel.
- **Engine over a cloud transport**: two-device and restore scenarios on the
  in-memory transport, including `movedTo` stubs and a removed slot that
  reappears.
- **Auth**: device-code polling (pending, slow_down, expired, denied), PKCE
  loopback, refresh and `invalid_grant`, against a fake token endpoint.
- **Swift**: XCTests for record and payload mapping and error translation.
- **UI**: widget tests for the picker, restore entries, switch prompt and the
  new statuses; TV focus tests for the device-code screen.
- **Manual before merge**: a real Google account across Android TV, Linux and
  iOS; a real iCloud account on the Mac simulator.

## Compatibility

A device on a build without cloud stores, in a group that switched to one,
keeps using the relay vault alone. A `movedTo` stub on the relay is an empty
record list with an extra top-level field, so an older build reads it as a
slot with no records and merges nothing; the plan confirms #1414's decoder
ignores the unknown field rather than rejecting the slot. Updating that
device brings the Switch prompt. Nothing on the relay changes.
