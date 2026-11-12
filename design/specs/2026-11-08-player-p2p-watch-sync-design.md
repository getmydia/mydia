# Peer-to-peer watch-state sync in the player

## Why

The files library (`design/specs/2026-11-06-player-files-library-design.md` and
`design/specs/2026-11-07-player-smb-files-design.md`) turns local folders,
WebDAV shares, and SMB shares into a matched library without a Mydia server.
Because there is no server, watch state, resume positions, and manual "Fix
match" pins stay on the device where they were made. A viewer who starts a
movie on their TV from an SMB share and opens the same share on their laptop or
phone sees it as unwatched, and any manual match fix has to be repeated on each
device.

At the same time, two standalone players with no Mydia server have no way to
discover or authorize each other for remote control, because `MergedRoster`
only reads Mydia server rosters.

## Goal

Let a viewer pair their own player devices directly over iroh P2P into a
personal sync group—with no Mydia server required—so that:

- Pairing any new device with any existing group member joins it to the whole
  group transitively, and revoking a device removes it across the group.
- Watch state, playback resume positions, and manual "Fix match" pins sync
  automatically across all paired devices (and across all `FilesMediaSource`
  accounts on the same device).
- Paired devices join `MergedRoster`, so they can remote-control and cast to
  each other even when no Mydia server is configured.
- The same paired group and P2P trust model will serve as the foundation for
  Sub-spec 2 (peer-to-peer file sharing of local folders).

## Decisions

| Question | Decision |
| --- | --- |
| How devices pair | 6-character claim code (via `pairing_seal` and `metadata-relay` `/pairing/v2/claim`) or QR code (`{node_addr, claim_code}`) |
| Group topology | Transitive sync group sharing a 32-byte `groupSecret`; pairing with one member introduces the rest via a replicated `PeerGroupRoster` |
| What syncs | Matched movie/episode watch state & resume positions (by TMDB ID), unmatched file watch state & resume positions (by `(accountId, fileKey)`), and manual "Fix match" pins (by `(isShow, groupKey)`) |
| Conflict resolution | Last-Write-Wins (LWW) per canonical key using origin `updatedAt`, with separate local `landedAt` watermarks for transitive anti-entropy |
| Watch + position atomicity | Combined into a single LWW `PeerWatchRecord` per item so marking an item unwatched or watched atomically clears stale resume positions across peers |
| Wire transport | New `MydiaRequest::PeerSync` / `MydiaResponse::PeerSync` variant in `mydia_p2p_core` over the existing CBOR request/response channel |
| Remote control | `PeerGroupRoster` implements `DeviceRoster` and joins `MergedRoster` |
| UI location | Settings → Paired Devices (`/settings/paired-devices` and a pane in the desktop settings dialog) |

### Rejected

- **Per-device operation log with vector clocks:** playback progress ticks
  every 10 seconds during playback, which bloats an op-log unless intermediate
  entries for the same item are compacted—at which point it reduces to a
  per-key LWW table with extra bookkeeping.
- **`iroh-docs` / `iroh-gossip` in Rust:** pulls in a heavy dependency tree and
  a second on-disk database alongside Hive for state that is a few kilobytes of
  CBOR over the existing `MydiaRequest` pipe.
- **Pairwise-only trust:** requires $N(N-1)/2$ manual pairings as devices are
  added instead of one pairing per new device.

## Architecture

### Rust: `native/mydia_p2p_core` and `player/rust/mydia_player_p2p`

- **`mydia_p2p_core` (`src/lib.rs`, `src/peer_sync.rs`).** Adds
  `MydiaRequest::PeerSync(PeerSyncRequest)` and
  `MydiaResponse::PeerSync(PeerSyncResponse)`:
  - `PeerSyncRequest::Pair { claim_code, device_name, platform, endpoint_addr }`
  - `PeerSyncRequest::Sync { auth_proof, sender_endpoint_addr, roster, since_landed_ms, records }`
  - `PeerSyncResponse::Paired { group_secret, roster, records }`
  - `PeerSyncResponse::PairRejected { reason }`
  - `PeerSyncResponse::SyncAck { roster, records, peer_now_ms }`
  - `PeerSyncResponse::NotAuthorized`
- **`mydia_player_p2p` (`src/lib.rs`).**
  - Routes inbound `Event::RequestReceived` with `MydiaRequest::PeerSync` onto
    a bounded 32-slot `peer_sync_rx` channel inside `run_event_dispatcher`
    (using `try_send`, identical to `control_rx` so a slow consumer never stalls
    generic P2P events).
  - Exposes `peer_sync_stream()`, `send_peer_sync(peer, req)`, and
    `respond_to_peer_sync(request_id, res)` on `P2pHost`.
  - Adds `PairingKeys::seal(node_addr, instance_id) -> FlutterSealedClaim` wrapping
    `mydia_p2p_core::pairing_seal::seal_claim`, so the player can publish a
    blinded claim to `metadata-relay` just as the server does.

### Dart: Relay & Pairing (`player/lib/core/relay/` and `player/lib/core/p2p/`)

- **`RelayApiClient` (`core/relay/relay_api_client.dart`).** Adds
  `publishClaimCode({required String lookupKey, required String sealed})`
  (`POST /pairing/v2/claim`) and `deleteClaimCode(String lookupKey)`
  (`DELETE /pairing/v2/claim/$lookupKey`), alongside the existing
  `resolveClaimCode`.
- **`PeerGroupSecret` (`core/p2p/peer_group_secret.dart`).** Stored in
  `AuthStorage` under `peer_group/secret` as base64url (32 random bytes).
  Derives:
  - `groupId`: first 16 hex chars of `SHA-256("mydia/peer-group/id/v1" || secret)`
  - `authProof(String senderNodeId)`: lowercase hex of
    `HMAC-SHA256(secret, utf8.encode("mydia/peer-group/auth/v1|$senderNodeId"))`
- **Pairing flow:**
  1. **Host (Show code / QR):** Ensures `P2pService` is initialized and has a
     `nodeAddr`. Loads or creates `groupSecret` in `AuthStorage`. Generates a
     6-character code from the unambiguous 31-character alphabet
     (`ABCDEFGHJKMNPQRSTUVWXYZ23456789`), seals `ClaimPayload(nodeAddr,
     "peer:$groupId")`, posts it to `/pairing/v2/claim`, and holds the active
     code in memory for 5 minutes (invalidating it early after 5 failed `Pair`
     attempts or as soon as one succeeds).
  2. **Joiner (Enter code / Scan QR):** Resolves the code via `RelayApiClient`
     (or reads `{node_addr, claim_code}` from the QR JSON), dials `nodeAddr`,
     and sends `PeerSyncRequest.pair(...)`.
  3. **Handshake & state merge:** On a valid `claim_code`, the host adds the
     joiner (and its `endpointAddr`) to its `PeerGroupRoster`, deletes the
     claim from the relay, and responds with `Paired { groupSecret, roster,
     records }`. The joiner saves `groupSecret` to `AuthStorage`, merges the
     host's roster and LWW records with its own pre-existing local records (and
     any non-revoked members if it was previously in another group), and
     immediately sends a `Sync` back to the host (and any other members in the
     merged roster) so both sides converge in one step.

### Transitive Roster & Remote Control (`core/p2p/peer_group_roster.dart`)

- **`PeerMember` record:**
  ```dart
  class PeerMember {
    final String nodeId;
    final String deviceName;
    final String platform;
    final String? endpointAddrJson;
    final int updatedAt; // ms since epoch
    final bool revoked;
  }
  ```
- **LWW Roster Merge:** For each `nodeId`, the entry with the higher
  `updatedAt` wins; on a timestamp tie, `revoked: true` wins over `false`.
- **Authorization check:** An inbound `Sync` request from `peer` (authenticated
  by iroh's QUIC handshake) is accepted if and only if:
  1. `constantTimeEquals(req.authProof, groupSecret.authProof(peer))` is true, and
  2. After merging `req.roster` into the local roster, `roster[peer]?.revoked != true`.
- **Revoking & Leaving:**
  - **Remove device:** Writes `member.copyWith(revoked: true, updatedAt: now)`
    into the roster and triggers a `Sync` push to all active peers.
  - **Leave group:** Marks this device's own `nodeId` as `revoked: true,
    updatedAt: now`, attempts a best-effort `Sync` push to active peers (3s
    timeout), deletes `peer_group/secret` from `AuthStorage`, and clears the
    roster in Hive while keeping all local watch/progress/pin records.
- **`DeviceRoster` implementation:** `PeerGroupRoster` implements `DeviceRoster`
  (`entries()` returns non-revoked peers excluding this device's own `nodeId`;
  `allows(peerNodeId)` checks active membership) and is passed into
  `MergedRoster` (`core/remote/merged_roster.dart`) alongside the Mydia
  instances' `RemoteRoster`s.

## Identity & State Model

### Storage: `PeerSyncStore` (`core/p2p/peer_sync_store.dart`)

Backed by a plain Hive `Box<Map<dynamic, dynamic>>` named `peer_sync` (added to
`kMydiaHiveBoxes` and opened in `openFilesLibraryBoxes()` so reads are
synchronous).

### Canonical Keys (`SyncKey`)

1. **Matched movies & episodes (cross-account across all `FilesMediaSource`s):**
   - `tmdb:movie:<tmdbId>`
   - `tmdb:ep:<tmdbId>:<season>:<episode>`
2. **Unmatched files (scoped to the files account):**
   - `file:<accountId>:<fileKey>`
   - For WebDAV (`w<sha16>`) and SMB (`s<sha16>`), `accountId`, `rootId`
     (`r<sha12(rootPath)>`), and `fileKey` (`sha16("$rootId/$relativePath")`)
     are deterministic, so two devices with the same share and root folder share
     unmatched file state as well.
   - Provisional items (`p<sha16>`) stay in `FileLibraryIndex` /
     `PlaybackProgressStore` until `FileMatcher` resolves them to a TMDB ID and
     migrates their state into `PeerSyncStore`.
3. **Manual "Fix match" pins (cross-account across all `FilesMediaSource`s):**
   - `pin:m:<groupKey>` (movie groups) and `pin:s:<groupKey>` (show groups),
     where `groupKey` is the normalized key produced by `mydia_media_names`.

### Record Shapes

1. **`PeerWatchRecord`** (for `tmdb:*` and `file:*` keys):
   ```dart
   class PeerWatchRecord {
     final String key;
     final bool watched;
     final int? positionSeconds;
     final int? durationSeconds;
     final int updatedAt; // origin wall-clock ms
     final int landedAt;  // local receipt ms (not sent on wire)
   }
   ```
   - **`setWatched(ref, true)`:** `watched: true, positionSeconds: null, durationSeconds: null, updatedAt: now`
   - **`setWatched(ref, false)`:** `watched: false, positionSeconds: null, durationSeconds: null, updatedAt: now`
   - **`removeFromContinueWatching(ref)`:** `watched: current.watched, positionSeconds: null, durationSeconds: null, updatedAt: now`
   - **Playback progress save (`pos`, `dur`):**
     `watched: current.watched || (dur > 0 && pos / dur >= kFilesWatchedFraction), positionSeconds: pos, durationSeconds: dur, updatedAt: now`

2. **`PeerPinRecord`** (for `pin:*` keys):
   ```dart
   class PeerPinRecord {
     final String key;      // 'pin:m:<groupKey>' or 'pin:s:<groupKey>'
     final String groupKey;
     final bool isShow;
     final int? tmdbId;     // null when explicitly unmatched to Folders
     final bool pinned;     // false is an unpin tombstone
     final int updatedAt;
     final int landedAt;
   }
   ```

### Conflict Resolution & Clock Skew

- Incoming `updatedAt` values further than 60 seconds in the future of the
  receiving device's clock (`localNow + 60_000`) are clamped to
  `localNow + 60_000` before comparison and storage, so a device with a
  misconfigured clock cannot permanently freeze a key.
- A record replaces the existing record at `key` when `incoming.updatedAt >
  local.updatedAt` (or on equal `updatedAt`, when `incoming.watched &&
  !local.watched`, or higher `positionSeconds ?? -1`).
- Whenever a record is written locally or accepted from a peer, its local
  `landedAt` is set to `max(localNow, lastIssuedLandedAt + 1)` so `landedAt` is
  strictly monotonic on each device.

### `FilesMediaSource` Integration & Initial Seeding

- **Seeding on first open:** When `PeerSyncStore` runs for the first time
  (`_seeded` marker absent in `peer_sync`), it imports existing watched flags
  and pinned `GroupMatch` entries from every account in `files_index` and
  existing `files` source progress entries from `playback_progress`.
- **Reading:** `FilesCatalog` reads watch state and resume positions for
  `tmdb:*` and `file:<accountId>:*` keys from `PeerSyncStore`, falling back to
  `FileLibraryIndex` / `PlaybackProgressStore` only for provisional `p<sha16>`
  items.
- **Writing:**
  - `FilesMediaSource.setWatched`, `removeFromContinueWatching`, and
    `FilesPlaybackSession`'s `ProgressReporter` write through `PeerSyncStore`.
  - When a `tmdb:*` key changes (locally or from a peer sync), `PeerSyncService`
    invalidates `SourceRules.watchedChanged(sourceId)` across every active
    `FilesMediaSource` on this device, so two local shares with the same movie
    stay in lockstep too.
  - When a `pin:*` record lands from a peer (or is already present in
    `PeerSyncStore` when `FileMatcher` scans a group), `FileMatcher` applies the
    pin to any local `FileLibraryIndex` holding that `groupKey`, fetches the
    TMDB movie/show details from the relay if missing locally, migrates any
    provisional/file state, and invalidates
    `FilesMediaSource.groupLandedTargets(sourceId)`.

## Sync Flow & Offline Convergence

1. **Per-peer watermarks:** `PeerSyncStore` tracks `peerWatermarks: Map<nodeId,
   ({int lastSentLandedAt, int lastPeerNowMs, int lastSyncedAt})>`.
2. **One-round-trip `Sync`:** When Device A syncs with Device B:
   - Before dialing `nodeB` by bare node ID, A passes B's last known
     `endpointAddrJson` (if any) to `P2pService.addAddressHint`.
   - A sends `PeerSyncRequest.sync` with `sinceLandedMs =
     watermark[nodeB].lastPeerNowMs` and all local records where `landedAt >
     watermark[nodeB].lastSentLandedAt`.
   - B merges A's roster and records, and replies with `SyncAck` containing B's
     merged roster, `peerNowMs`, and all records on B where `landedAt >
     sinceLandedMs` (excluding records that just arrived in A's request).
   - Both sides update their watermarks and invalidate any affected
     `FilesMediaSource` caches.
3. **Triggers:**
   - **App start, foreground resume (`connectionRefreshBusProvider`), and
     `P2pService.onPeerConnected`:** syncs with all active peers in the roster.
   - **Local mutations:** immediate sync on `setWatched`,
     `removeFromContinueWatching`, `setMatch` (pin), and playback pause/stop;
     throttled to at most once every 30 seconds during active playback ticks.
   - **Cooldown on unreachable peers:** a peer whose dial or request fails is
     skipped for 60 seconds (cleared on `connectionRefreshBusProvider` or when
     that peer initiates an inbound connection) so an offline device never
     blocks playback or floods dials.

## UI

- **Navigation:**
  - `SettingsNav` gains `openPairedDevices()`.
  - `RouterSettingsNav` pushes `/settings/paired-devices` (`PairedDevicesScreen`).
  - `DialogSettingsNav` opens `PairedDevicesBody` inside the desktop settings
    dialog.
  - `ManageSettingsSection` (mobile/TV) and the desktop settings dialog include
    a **Paired Devices** row showing the count of active paired peers (or "Not
    paired").
- **`PairedDevicesBody`:**
  - **Pair a new device (Show code / QR):** Displays a QR code and the
    formatted 6-character code (`ABC-123`) with its expiry countdown. Closes
    automatically and shows a confirmation toast when a peer completes the
    `Pair` handshake.
  - **Enter code / Scan QR:** 6-character code input field (and camera QR
    scanner button on mobile platforms) with step feedback (`Resolving code…`,
    `Connecting…`, `Paired`).
  - **Paired devices list:** Shows each active peer's name, platform icon, and
    status (`Connected`, `Last synced …`, or `Offline`), with a **Remove**
    button per peer.
  - **Footer actions:** **Sync now** button and **Leave group** (with
    confirmation dialog).

## Errors

- **Invalid or expired claim code:** "Invalid or expired pairing code." After 5
  wrong guesses against a live host code, the host discards the active code and
  rotates a new one.
- **Relay unreachable during code lookup/publish:** "Could not reach the pairing
  relay. If both devices are on the same network, scan the QR code instead."
  (QR code carries `nodeAddr` directly and needs no HTTP relay lookup.)
- **Peer offline during sync:** Silently deferred with a 60-second cooldown;
  changes are already in `peer_sync` and will reconcile on the next connection.
- **Relay unreachable when applying a synced pin:** The `PeerPinRecord` is saved
  in `peer_sync`, and `FileMatcher` fetches the TMDB metadata on the next scan
  or refresh once the relay is reachable.
- **Tampered or unauthorized `Sync` request:** Refused with
  `PeerSyncResponse::NotAuthorized`; roster and state are untouched.

## Out of scope

- **Peer-to-peer file sharing** (browsing and streaming another paired player's
  local folders over iroh P2P): covered in **Sub-spec 2**, which builds directly
  on `PeerGroupRoster` and `groupSecret`.
- Syncing WebDAV or SMB credentials across devices.
- Syncing watch state for server-backed sources (Mydia, Plex, Jellyfin, Stash),
  which already sync through their respective servers.

## Testing

- **Rust (`mydia_p2p_core` & `mydia_player_p2p`):**
  - CBOR wire-format round-trip tests for `PeerSyncRequest` and
    `PeerSyncResponse`.
  - Two-node loopback test (`tests/two_node_peer_sync.rs`) covering `Pair` and
    `Sync` request/response delivery and `PairingKeys::seal` → `open`.
- **Dart unit:**
  - `PeerSyncStore`: LWW merge rules, future-timestamp clamping, monotonic
    `landedAt` advancement, atomic `watched` + `positionSeconds` transitions
    (marking unwatched clears a 95% position), pin tombstones, and initial
    seeding from `FileLibraryIndex` and `PlaybackProgressStore`.
  - `PeerGroupRoster`: HMAC proof verification, LWW member merge, revocation
    tombstones, leaving a group, and `MergedRoster` remote-control inclusion.
  - `PeerSyncService`: Three-peer transitive convergence test (A syncs with B,
    A goes offline, B syncs with C → C receives A's watch state, pins, and
    roster updates; C revokes A → B learns the revocation from C and refuses A).
  - `FilesMediaSource`: Cross-account TMDB watch/progress sharing between two
    local `FilesMediaSource` instances, and unmatched file (`file:<accountId>:<fileKey>`)
    sync across matching SMB/WebDAV accounts.
- **Widget:**
  - `PairedDevicesBody` showing a code, entering a code, listing peers,
    removing a peer, and leaving the group, plus `untranslated_text_test.dart`
    coverage.
