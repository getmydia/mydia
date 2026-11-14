# Peer-to-peer file sharing between paired players

## Why

The files library (`2026-11-06-player-files-library-design.md`) turns local
folders, SMB and WebDAV shares into a matched library, and P2P watch sync
(`2026-11-08-player-p2p-watch-sync-design.md`) pairs a viewer's own devices
into a group that shares watch state and Fix match pins. The library itself
still lives on one device. A movie in a folder on the living-room desktop
cannot be played from the laptop, and a phone away from home cannot reach the
home NAS at all.

The watch sync spec reserved this as Sub-spec 2: browsing and streaming
another paired player's library over iroh, built on `PeerGroupRoster` and the
group secret.

## Goal

Every Files account on a paired player (local folders, SMB and WebDAV) shows
up on the other members of its sync group as a ready, matched library, and
plays over P2P. Specifically:

- The viewer sees the host's library instantly from a replicated copy of the
  host's index, with no rescan and no TMDB matching on the viewer.
- Bytes stream on play, through the same local proxy and range machinery that
  Mydia-server playback over P2P already uses.
- A peer copy of an SMB or WebDAV share that this device has already added
  directly is hidden, so nothing appears twice.
- Watch state and resume positions keep flowing through the existing
  PeerSync, keyed so that the viewer and the host share one record per item.

## Decisions

| Question | Decision |
| --- | --- |
| What a viewer can do | Browse and stream a paired device's Files library. Nothing is copied to the viewer. |
| Who can see it | Active, non-revoked members of the host's sync group. No sharing outside the group. |
| What a host shares | All its Files accounts: local folders, SMB and WebDAV. The host relays SMB and WebDAV bytes. |
| How a library appears | The host's matched index is replicated to the viewer and rendered by the existing Files source. |
| Duplicates | A peer SMB/WebDAV account matching one this device already has is skipped. Local folders are never skipped. |
| Wire transport | New `MydiaRequest::PeerFiles` variant for the manifest and index pages; reads reuse `MydiaRequest::HlsStream` with a `peerfile:` session. |
| Who serves bytes on the host | Rust, from grants that Dart resolves on demand. Bytes never enter Dart on the host. |
| Index updates | Full re-fetch of one account when its revision changes, in pages of at most 4 MiB. No diffs. |

### Rejected

- **Host pumps bytes through Dart.** Every byte would cross FFI twice on the
  host, and the host side would need its own backpressure. The viewer side
  already has flow control in `P2pRangeStream`.
- **Index records inside PeerSync.** The index belongs to one host and is not
  last-write-wins group state. Gossip would store every device's whole index
  on every other device and mix library data into the sync store.
- **Peer as a scannable `FileSystemBackend`.** Each viewer would repeat the
  scan and TMDB matching, slowly over relay, and would disagree with the host
  on match results.
- **Live remote browsing with no local copy.** Nothing shows while the host
  is offline, and every screen waits on P2P round trips.

## Architecture

### Wire protocol: `native/mydia_p2p_core/src/peer_files.rs`

A new module, free of iroh and I/O like `peer_sync.rs`, defines:

```rust
pub enum PeerFilesRequest {
    Manifest { auth_proof: String },
    IndexPage {
        auth_proof: String,
        account_id: String,
        revision: u64,
        cursor: Option<String>,
    },
}

pub enum PeerFilesResponse {
    Manifest { accounts: Vec<WireSharedAccount> },
    IndexPage { records: WireIndexPage, next_cursor: Option<String> },
    StaleRevision,
    NotAuthorized,
}

pub struct WireSharedAccount {
    pub account_id: String,
    pub kind: String,           // "local" | "smb" | "webdav"
    pub name: String,
    pub dedupe_key: Option<String>,
    pub revision: u64,
}
```

`WireIndexPage` carries roots, indexed files, group matches and the cached
`MatchedMovie`, `MatchedShow` and `MatchedEpisode` records, mirroring
`index_records.dart`. It never carries credentials or watch state.

`MydiaRequest::PeerFiles(PeerFilesRequest)` is added to the request enum.

- `Manifest` and `IndexPage` are request/response. p2p responses are capped
  at 8 MiB (`MAX_RESPONSE_BYTES`), so the host fills a page up to 4 MiB of
  encoded CBOR and returns a cursor for the rest.
- **Reads reuse `MydiaRequest::HlsStream`.** A read is an `HlsRequest` whose
  `session_id` is `peerfile:<host account id>` and whose `path` is the
  base64url of the host's file path, with the request's range. The core
  already streams `HlsStream` responses from a host (`send_hls_header`,
  `send_hls_chunk`, `stream_file_range`), and the viewer's `LocalProxyService`
  already turns mpv's HTTP ranges into `HlsStream` requests through
  `openRangeStream`, so the viewer side needs no new Rust. Status 206 or 200
  on success, 403 for a caller that is not an active member, 404 for a path
  that is neither an indexed file nor one of its sidecars, 502 when the
  host's own backend fails.
- The Elixir server listener rejects `PeerFiles`, as it does `PeerSync`. A
  `peerfile:` session sent to a server finds no session there.
- The web player is neither host nor viewer: `sourceKindAllowedOnWeb` admits
  only Mydia sources.

### Authorization

PeerSync authorizes a caller with an HMAC proof of the group secret plus a
roster check that the node is known and not revoked
(`peer_sync_service.dart`). `Manifest` and `IndexPage` run exactly those two
checks in Dart.

Reads are checked in Rust. iroh authenticates the remote node ID at the QUIC
layer, so Rust holds an allowlist of active member node IDs and rejects any
read from a node outside it. Dart replaces the allowlist on startup, on every
roster change, and with an empty list when the device leaves its group.

### Host side

**`PeerFilesHost`** (`player/lib/core/p2p/peer_files_host.dart`) runs only
while the device belongs to a sync group.

- It listens on a new `peer_files_stream` from `mydia_player_p2p` and answers
  with `respond_to_peer_files`, the same shape as `peer_sync_stream` and
  `respond_to_peer_sync`.
- `Manifest` lists every Files account with its `revision` and `dedupe_key`.
  The key is the existing normalized identity: `normalizeSmbUrl` plus the
  share path for SMB, `normalizeWebDavUrl` for WebDAV, null for local
  folders.
- `IndexPage` reads `FileLibraryIndex` directly. Paths are sent as the host
  stores them: they only mean something to the host, which is also the only
  device that resolves them. If the account's revision no longer equals the
  requested one, the answer is `StaleRevision`.
- One revision counter per account, persisted in Hive, bumps when
  `FilesScanController` finishes a scan and when a match or pin changes.
- It pushes the member allowlist into Rust.

**Grants.** The host does not pre-register files. On a read for an
`(account_id, path)` it has no grant for, Rust makes one call into Dart
(`peer_file_grant_stream`, answered with `respond_peer_file_grant`). Dart
accepts the path only if it is an indexed file of that account or one of its
sidecars, calls the backend's `playable()`, and returns the URL and headers,
or not found.
Rust caches grants per account and drops an account's cache when its revision
bumps (Dart tells it) and after any failed read, so a re-addressed SMB share
resolves again.

**Byte serving** (`player/rust/mydia_player_p2p/src/peer_files_host.rs`):

- A file path is opened and read from the requested offset.
- An `http(s)` URL (the loopback URL `mydia_smb` serves for SMB, or a WebDAV
  URL with its auth headers) is read with a ranged GET through `reqwest`
  0.12 with rustls, already in the lockfile through `mydia_smb`.
- Chunks are written to the response stream as they arrive and the upstream
  read stops when the viewer cancels.
- At most 4 concurrent reads per peer. Further reads wait for a slot.

### Viewer side

**`PeerFilesClient`** (`player/lib/core/p2p/peer_files_client.dart`) builds
the shared libraries.

- For every active member it fetches the `Manifest` on startup, after each
  successful PeerSync round with that member, and on pull to refresh.
- For each account whose revision changed, it fetches every `IndexPage` into
  a new generation in the `peer_files_index` Hive box and flips that
  account's generation pointer once the last page arrives, then deletes the
  old generation. A failed or interrupted fetch leaves the previous copy in
  place. `StaleRevision` restarts the fetch, at most twice per round.

**Peer sources.** Each `(peerNodeId, hostAccountId)` becomes a derived
`Source` of kind `SourceKind.files`, flagged as a peer source.

- It is labelled with the peer's device name and the account name, for
  example "Living Room TV · Movies".
- It is never created by the Add source flow and never written to the source
  list as an editable record. It cannot be renamed, rescanned or deleted from
  the viewer.
- Its index box loads into the existing `FileLibraryIndex`, so Home, detail,
  Folders, search and Continue Watching render it unchanged. The Folders view
  already reads from the index (`files_queries.dart`), not from the backend.
- Its own account id is `p` + the first 12 hex characters of SHA-256 over the
  peer's node id, `_`, and the host's account id. Every device's local folders
  account is `flocal`, so the host's id alone would collide with the viewer's.
  `FilesMediaSource` gains a `syncAccountId`, set to the host's account id, and
  uses it wherever it builds or parses a sync key. Matched items sync by TMDB
  ID and unmatched files by `unmatchedFileSyncKey(syncAccountId, fileKey)`, so
  watch state and resume positions land on the host's records through
  PeerSync with no new sync work.
- It follows the existing All servers inclusion rules
  (`all_servers_inclusion.dart`).

**`PeerFilesBackend implements FileSystemBackend`:**

- `playable(path)` starts a `LocalProxyService` target for the peer and returns
  `MediaRoutes.peerFile(base, accountId, path)`, which the proxy forwards as
  a `peerfile:` range stream. Before returning, it opens a one-byte range
  (`0-0`) and maps the header's status to the errors below, so a dead host or
  a missing file fails at Play rather than inside mpv. Sidecar subtitles and
  casting through `FilesCastBridge` use the same call.
- `list`, `stat` and `probe` throw `BackendUnreachable`. The scan controller
  never runs for a peer source.

**Dedupe.** A peer account whose non-null `dedupe_key` matches the key of an
SMB or WebDAV account on this device is skipped, using the existing SMB
matching rules (by name or hostname, never by a shared IP). If the local
account is removed, the peer copy appears on the next manifest fetch.

**Removal.** A peer source and its box are removed when the account leaves
the manifest, when its host is revoked, or when this device leaves the group.

## Errors and offline

- **Host offline.** The replicated index stays, so the library still browses
  with posters and watch state. The source reports unreachable through
  `current_source_status`, from the member's last successful contact. Play
  tries one dial with the roster's address hints, then fails quickly with
  "Living Room TV isn't reachable. It needs to be on with Mydia Player open."
- **404** shows "This file is no longer on Living Room TV" and triggers a
  manifest fetch.
- **502** shows "Living Room TV can't reach its share right now". The host has
  already dropped that account's grants.
- **403** is treated as revocation: every peer source from that host is torn
  down.
- **Mid-playback drop.** `range_spool` retries the current range on a fresh
  stream. A host that stays gone surfaces as the existing playback error.
- **Relay.** The detail screen shows the existing via-relay connection badge.
  A player host cannot transcode, so high-bitrate files may stutter over the
  relay. This is a known limit.

## Platform notes

- **iOS hosts** stop serving when the app is backgrounded. Accepted: hosts are
  in practice desktops and TVs.
- **Local folders** exist only on Linux, Windows and macOS
  (`add_folder_screen.dart`), so their grants are always plain paths. Android
  and iOS hosts share their SMB and WebDAV accounts.

## Testing

**`native/mydia_p2p_core`:**

- `peer_files.rs` unit tests: CBOR round trips for every variant.
  `tests/wire_format.rs` covers the new `MydiaRequest` tag so existing tags
  cannot shift.
- `tests/two_node_peer_files.rs`, modelled on `two_node_peer_sync.rs`: a
  `PeerFiles` request reaches the other node as `RequestReceived` and its
  answer comes back.
- The server listener refuses `PeerFiles`.

**`mydia_player_p2p`:** the host byte server against a temp file and a local
HTTP server: exact bytes for a range, open-ended ranges, 403 for a
non-member, 404 for an unresolved grant, 502 on upstream failure, a cancel
mid-stream stops the upstream read, the fifth concurrent read from one peer
waits for a slot, and the grant cache is dropped on invalidation and after a
failed read.

**`player/test/core/p2p/`:**

- `peer_files_host_test.dart`: proof and roster rejection, paging under the
  4 MiB budget, `StaleRevision` when a scan finishes mid-fetch, allowlist
  pushes on roster change and on leaving the group.
- `peer_files_client_test.dart` against a fake transport: sources follow the
  manifest, revocation and leaving the group; dedupe hides a matching SMB or
  WebDAV account and never a local folder; a failed page keeps the old index;
  peer sources keep the host's `accountId`, so sync keys equal the host's.
- `peer_files_backend_test.dart`: `playable()` goes through
  `LocalProxyService` with `fake_range_stream.dart`; `list` and `stat` throw.
- A widget test renders Home and detail for a peer source from a replicated
  index with no backend `list` call.

**Manual:** two desktops paired on a LAN, then the same pair forced through
the relay. Play a local-folder movie, play from an SMB share on the host, cast
a peer file to a Chromecast, and confirm watch state reaches the host.

## Out of scope

- Copying or downloading a peer's file to the viewer for offline use.
- Sharing with anyone outside the viewer's own sync group.
- Transcoding on a player host.
- Per-account opt-out of sharing. Every Files account is shared with the
  group.
- Server-backed sources (Mydia, Plex, Jellyfin, Stash). They are already
  reachable from every device.
