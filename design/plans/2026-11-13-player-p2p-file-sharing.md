# P2P File Sharing Between Paired Players Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Files account on a paired player shows up on the other members of its sync group as a matched library that plays over iroh.

**Architecture:** A new `MydiaRequest::PeerFiles` request carries a manifest and paged index snapshots, which the viewer stores as a replicated `FileLibraryIndex` behind a derived, read-only `files` source. Reads reuse `MydiaRequest::HlsStream` with a `peerfile:` session. The host's Rust serves those reads straight from a file or an HTTP URL, using grants that Dart resolves on demand. The viewer's existing `LocalProxyService` and `openRangeStream` carry the bytes unchanged.

**Tech Stack:** Rust (`mydia_p2p_core`, `mydia_player_p2p`, iroh, serde_cbor, reqwest 0.12 rustls), flutter_rust_bridge, Dart/Flutter, Riverpod, Hive.

**Spec:** `design/specs/2026-11-13-player-p2p-file-sharing-design.md`

## Global Constraints

- Only active, non-revoked members of the host's sync group may read the manifest, index pages or file bytes.
- Index pages are at most 4 MiB of encoded CBOR (`MAX_RESPONSE_BYTES` is 8 MiB).
- At most 4 concurrent reads per peer on a host; the fifth waits for a slot.
- A read path must be an indexed file of the named account or one of that file's sidecars; anything else is 404.
- Never send credentials or watch state in `PeerFiles` responses.
- Peer source account id: `p` + first 12 hex chars of SHA-256(peer node id) + `_` + host account id.
- Session prefix for reads: `peerfile:`; read path is base64url (no padding) of the host's file path.
- Web is neither host nor viewer; local folders are desktop-only, so local grants are always plain paths.
- New Hive boxes go through `initAppHive()` and into `kMydiaHiveBoxes`.
- No real movie or TV titles in tests or fixtures; invent them.
- No em dashes in code comments, docs or copy.
- Commits: run `git commit` inside the devenv environment and verify each with `git show --stat`.

## Review Focus

1. **A file path with characters that break URLs** (spaces, `#`, `?`, non-ASCII, Windows `\`). Expect playback to work. Pinned in Task 7's route round-trip test.
2. **A host rescans while a viewer is mid-fetch.** Expect `StaleRevision`, a restart, and never a half-written index on screen. Pinned in Tasks 5 and 6.
3. **The viewer has its own `flocal` account and the host shares its `flocal`.** Expect two distinct sources and no collision of source ids or index keys. Pinned in Task 7.
4. **A host is revoked while a viewer is streaming from it.** Expect the next read to get 403 and the peer sources to disappear. Pinned in Tasks 3 and 7.
5. **A read asks for a path outside the index**, such as `../` or a sidecar of another account. Expect 404 with no backend call. Pinned in Task 5.

---

### Task 1: Wire types and the server's refusal

**Files:**
- Create: `native/mydia_p2p_core/src/peer_files.rs`
- Modify: `native/mydia_p2p_core/src/lib.rs` (module and re-export near line 62; `MydiaRequest` line 79; `MydiaResponse` line 145; a new `HlsResponder` beside `HlsRequester` near line 1007)
- Modify: `native/mydia_p2p/src/lib.rs:367-370` (add `MydiaRequest::PeerFiles(_)` to the refused arm and its comment)
- Test: `native/mydia_p2p_core/src/peer_files.rs` (unit), `native/mydia_p2p_core/tests/wire_format.rs`, `native/mydia_p2p_core/tests/two_node_peer_files.rs`

**Interfaces:**
- Produces:
  - `pub const PEER_FILE_SESSION_PREFIX: &str = "peerfile:";`
  - `pub const PEER_FILES_PAGE_BUDGET: usize = 4 * 1024 * 1024;`
  - `PeerFilesRequest::{Manifest { auth_proof: String }, IndexPage { auth_proof: String, account_id: String, revision: u64, cursor: Option<String> }}`
  - `PeerFilesResponse::{Manifest { accounts: Vec<WireSharedAccount> }, IndexPage { page: WireIndexPage, next_cursor: Option<String> }, StaleRevision, NotAuthorized}`
  - `WireSharedAccount { account_id, kind, name: String, dedupe_key: Option<String>, revision: u64 }`
  - `WireIndexPage { roots: Vec<Vec<u8>>, files: Vec<Vec<u8>>, groups: Vec<Vec<u8>>, movies: Vec<Vec<u8>>, shows: Vec<Vec<u8>> }`. Each element is one record as Dart encodes it (CBOR of the record's `toMap()`), so Rust never mirrors the Dart record shapes.
  - `MydiaRequest::PeerFiles(PeerFilesRequest)`, `MydiaResponse::PeerFiles(PeerFilesResponse)`, both appended last so existing tags keep their positions.
  - `#[cfg(feature = "host")] #[derive(Clone)] pub struct HlsResponder` from `Host::hls_responder()`, with async `send_header(stream_id, HlsResponseHeader)`, `send_chunk(stream_id, Vec<u8>)`, `finish(stream_id)`, `abort(stream_id)` and `stream_file_range(stream_id, path, offset, length)`. These are the same commands as the `Host` methods of those names.

- [ ] **Step 1: Write failing tests**
  - In `peer_files.rs`: `manifest_round_trips_cbor` and `index_page_round_trips_cbor`. Build each value, run `serde_cbor::to_vec` then `from_slice`, and `assert_eq!`. Also `stale_and_not_authorized_round_trip`.
  - In `wire_format.rs`: `peer_files_is_the_last_request_variant`. Assert that `MydiaRequest::PeerFiles(..)` and `MydiaResponse::PeerFiles(..)` encode under the variant names `"PeerFiles"`, and that the existing variants' encodings are unchanged, matching the file's current style.
  - `two_node_peer_files.rs`, modelled on `two_node_peer_sync.rs`: node A sends `PeerFilesRequest::Manifest`. Node B receives `Event::RequestReceived { request: MydiaRequest::PeerFiles(_), .. }` and answers `Manifest { accounts: vec![one account] }`. A receives exactly that.

- [ ] **Step 2: Run them and see them fail**
  Run: `cd native/mydia_p2p_core && cargo test peer_files && cargo test --test wire_format --test two_node_peer_files`
  Expected: compile errors, because `peer_files` is undefined.

- [ ] **Step 3: Implement the module, the enum variants and `HlsResponder`**
  Derive `Debug, Clone, PartialEq, Eq, Serialize, Deserialize` as in `peer_sync.rs`. Keep `peer_files.rs` free of iroh and I/O. Implement `HlsResponder` by cloning `cmd_tx` and sending the same `Command` variants the `Host` methods send.

- [ ] **Step 4: Add `PeerFiles` to the Elixir NIF's refused arm**
  The arm is in `native/mydia_p2p/src/lib.rs:367-370`.

- [ ] **Step 5: Run the tests and see them pass**
  Run: `cd native/mydia_p2p_core && cargo test && cd ../mydia_p2p && cargo test`
  Expected: PASS. Also run `cargo clippy --all-targets` in both crates with no warnings.

- [ ] **Step 6: Commit**
  `git add native/ && git commit -m "feat(p2p): PeerFiles wire types and a clone-able HLS responder"`

---

### Task 2: Player FFI for `PeerFiles` requests

**Files:**
- Modify: `player/rust/mydia_player_p2p/src/lib.rs`. Add a `peer_files_tx` arm in `run_event_dispatcher` (near line 1092), plus `peer_files_stream`, `send_peer_files` and `respond_to_peer_files` beside the peer sync trio (lines 1435-1483).
- Regenerate: `player/lib/native/` (FRB output, via `./dev player setup` or the crate's codegen command in `player/docs/workflow.md`)
- Modify: `player/lib/core/p2p/p2p_service.dart` (Dart wrappers next to the peer sync ones)
- Test: `player/rust/mydia_player_p2p/src/lib.rs` (dispatcher unit test next to the existing ones around line 2015), `player/test/core/p2p/p2p_service_peer_files_test.dart`

**Interfaces:**
- Consumes: Task 1's `PeerFilesRequest` and `PeerFilesResponse`.
- Produces:
  - Rust: `FlutterPeerFilesRequest` and `FlutterPeerFilesResponse` mirror enums with `From` both ways; `FlutterInboundPeerFilesRequest { peer, request_id, request }`; `P2pHost::peer_files_stream(sink)`; `P2pHost::send_peer_files(peer, req) -> FlutterPeerFilesResponse`; `P2pHost::respond_to_peer_files(request_id, res)`.
  - Dart: `P2pService.onPeerFilesRequest` (`Stream<FlutterInboundPeerFilesRequest>`), `sendPeerFiles(String peer, FlutterPeerFilesRequest req)`, `respondToPeerFiles(String requestId, FlutterPeerFilesResponse res)`.

- [ ] **Step 1: Write the failing dispatcher test**
  `peer_files_request_routes_to_peer_files_channel`: send `Event::RequestReceived { request: MydiaRequest::PeerFiles(Manifest{..}) }` into the dispatcher. Assert it arrives on the peer files receiver and not on the generic channel. Follow the shape of the existing peer sync routing test.

- [ ] **Step 2: Run it and see it fail**
  Run: `cd player/rust/mydia_player_p2p && cargo test peer_files_request_routes`
  Expected: FAIL to compile.

- [ ] **Step 3: Implement the arm, the mirror enums and the three methods**
  Use a channel capacity of 32 and the same warn-on-full wording as the peer sync arm.

- [ ] **Step 4: Regenerate the FRB bindings and add the Dart wrappers**
  The wrappers mirror `sendPeerSync`, `respondToPeerSync` and `onPeerSyncRequest` in `p2p_service.dart`.

- [ ] **Step 5: Write and run the Dart wrapper test**
  `p2p_service_peer_files_test.dart` follows `p2p_service_peer_sync_test.dart`. It asserts that an inbound request surfaces on `onPeerFilesRequest` and that `respondToPeerFiles` reaches the host fake.
  Run: `./dev flutter test test/core/p2p/p2p_service_peer_files_test.dart` and `cargo test`.
  Expected: PASS.

- [ ] **Step 6: Commit**
  `git commit -m "feat(player): PeerFiles requests over the player p2p bridge"`

---

### Task 3: Host byte server in Rust

**Files:**
- Create: `player/rust/mydia_player_p2p/src/peer_files_host.rs`
- Modify: `player/rust/mydia_player_p2p/src/lib.rs`. In `run_event_dispatcher`, route `Event::HlsStreamRequest` whose `request.session_id` starts with `PEER_FILE_SESSION_PREFIX` to `PeerFilesHost::serve`; every other request goes to the generic channel as today. Add the FFI methods below to `P2pHost`.
- Modify: `player/rust/mydia_player_p2p/Cargo.toml`. Add `reqwest = { version = "0.12", default-features = false, features = ["rustls-tls", "stream"] }`, `base64`, and `futures-util` if it is not already present, all under the non-wasm target section. Add `hyper` and `hyper-util` (matching `mydia_smb`'s versions) plus `tempfile` as dev-dependencies.
- Test: unit tests inside `peer_files_host.rs`

**Interfaces:**
- Consumes: Task 1's `HlsResponder` and `PEER_FILE_SESSION_PREFIX`.
- Produces:
  - FFI on `P2pHost`:
    - `set_peer_files_members(node_ids: Vec<String>)`
    - `peer_file_grant_stream(sink: StreamSink<FlutterPeerFileGrantRequest>)`, where `FlutterPeerFileGrantRequest { request_id, account_id, path }`
    - `respond_peer_file_grant(request_id: String, grant: Option<FlutterPeerFileGrant>)`, where `FlutterPeerFileGrant { url: String, headers: Vec<(String, String)> }`
    - `invalidate_peer_file_grants(account_id: String)`
  - Internal:
    - `trait ByteSink { async fn header(&self, h: HlsResponseHeader) -> Result<(), String>; async fn chunk(&self, b: Vec<u8>) -> Result<(), String>; async fn finish(&self); async fn abort(&self); }`. It is implemented for `(HlsResponder, stream_id)` and for a test recorder.
    - `PeerFilesHost::serve(peer, HlsRequest, sink)`.

Behaviour that the tests pin:
- A `peer` that is not in the members set gets status 403 with an empty body. The allowlist starts empty.
- `path` is base64url-decoded. If that fails, or the grant resolves to `None`, or Dart doesn't answer within 10 s, the reply is 404.
- Grants are cached per `(account_id, path)`. `invalidate_peer_file_grants` clears that account's entries, and any upstream failure evicts the entry it used.
- A grant URL without a scheme, or with scheme `file`, is a local path. Rust sends a header (206 with `Content-Range: bytes s-e/total` when a range was asked for, otherwise 200; `content_type` from the file extension, with `application/octet-stream` as the fallback). It then calls `stream_file_range`.
- An `http`/`https` grant is fetched with a ranged GET that carries the grant's headers. The upstream's status, length and range are forwarded, and its body is chunked through `ByteSink::chunk`. An upstream connection error or status ≥ 400 becomes 502.
- A `Semaphore(4)` per peer; the permit is held for the whole stream.
- When `chunk` returns `Err` (the viewer cancelled), the upstream body is dropped and nothing more is read.

- [ ] **Step 1: Write the failing tests**
  All of these run against a `RecordingSink`, a temp file holding bytes `0..=255` repeated to 1 MiB, and a hyper server on `127.0.0.1:0` serving that same buffer with Range support.
  - `non_member_gets_403`
  - `unknown_grant_gets_404`
  - `bad_base64_path_gets_404`
  - `file_range_returns_exact_bytes`: range `100-199` gives status 206, `Content-Range` `bytes 100-199/1048576`, and bytes equal to `buf[100..200]`.
  - `file_open_ended_range`: `range_start: 1048000`, no end, gives the last 576 bytes.
  - `http_range_forwards_status_and_bytes`
  - `http_upstream_500_becomes_502`
  - `cancel_stops_upstream_reads`: the sink errors after the first chunk. The test server counts bytes written and stays under 256 KiB.
  - `fifth_read_waits_for_a_slot`: four streams are held open, a fifth `serve` has not sent its header after 100 ms, and it does once one is released.
  - `invalidate_drops_cached_grant`: the second resolve after invalidation calls the resolver again.
  - `failed_read_evicts_grant`

- [ ] **Step 2: Run them and see them fail**
  Run: `cd player/rust/mydia_player_p2p && cargo test peer_files_host`
  Expected: FAIL to compile.

- [ ] **Step 3: Implement `peer_files_host.rs` and the dispatcher routing**
  The grant resolver is a `trait GrantResolver { async fn resolve(&self, account_id: &str, path: &str) -> Option<Grant>; }`. The production version sends a `FlutterPeerFileGrantRequest` and awaits a oneshot stored in a pending map under `request_id`; tests use an in-memory resolver.

- [ ] **Step 4: Expose the four FFI methods and regenerate the FRB bindings**

- [ ] **Step 5: Run the tests and lints**
  Run: `cargo test && cargo clippy --all-targets -- -D warnings`
  Expected: PASS.

- [ ] **Step 6: Commit**
  `git commit -m "feat(player): serve peerfile reads from grants in Rust"`

---

### Task 4: Dart transport wrappers for the host

**Files:**
- Modify: `player/lib/core/p2p/p2p_service.dart`
- Test: `player/test/core/p2p/p2p_service_peer_files_test.dart` (extend the file from Task 2)

**Interfaces:**
- Consumes: Task 3's FFI.
- Produces on `P2pService`:
  - `Future<void> setPeerFilesMembers(List<String> nodeIds)`
  - `Stream<FlutterPeerFileGrantRequest> get onPeerFileGrantRequest`
  - `Future<void> respondPeerFileGrant(String requestId, FlutterPeerFileGrant? grant)`
  - `Future<void> invalidatePeerFileGrants(String accountId)`
- Produces: a `PeerFilesTransport` interface in `player/lib/core/p2p/peer_files_transport.dart`. It holds those four members plus Task 2's `onPeerFilesRequest`, `sendPeerFiles` and `respondToPeerFiles`, and `openRangeStream` from `P2pService`. A `P2pPeerFilesTransport` adapter implements it, in the same style as `PeerSyncTransport` in `peer_sync_service.dart:26`. Tasks 5 to 7 depend only on this interface.

- [ ] **Step 1: Write the failing tests**
  The adapter forwards each call to a fake `P2pService` host, and the grant-request stream surfaces inbound requests.
- [ ] **Step 2: Run them and see them fail**
  Run: `./dev flutter test test/core/p2p/p2p_service_peer_files_test.dart`
- [ ] **Step 3: Implement the wrappers and the adapter**
- [ ] **Step 4: Run them and see them pass**
- [ ] **Step 5: Commit**
  `git commit -m "feat(player): PeerFilesTransport over P2pService"`

---

### Task 5: `PeerFilesHost` in Dart

**Files:**
- Create: `player/lib/core/p2p/peer_files_host.dart`
- Create: `player/lib/core/p2p/peer_files_wire.dart`. It encodes and decodes the index records to and from `WireIndexPage` byte entries using the records' existing `toMap()`/`fromMap()` (`index_records.dart`) wrapped in CBOR. Add `cbor` only if no CBOR package is already in `pubspec.yaml`; otherwise use the one that is there.
- Modify: `player/lib/core/sources/files/files_scan_controller.dart` (call `PeerFilesHost.bumpRevision(accountId)` when `rescan()` completes successfully)
- Modify: the Fix match and pin write path in `FilesMediaSource`/`FileMatcher` (call the same bump after a pin or match write)
- Modify: `player/lib/core/storage/hive_box_migration.dart` (`kMydiaHiveBoxes` += `'peer_files_revisions'`) and `initAppHive()`
- Modify: the app's p2p startup, where `peerSyncServiceProvider` is started (start `peerFilesHostProvider` beside it)
- Test: `player/test/core/p2p/peer_files_host_test.dart`, `player/test/core/p2p/peer_files_wire_test.dart`

**Interfaces:**
- Consumes: `PeerFilesTransport` (Task 4); `PeerSyncService.onStateChanged`, its member store and `PeerGroupSecret.verifyAuthProof` (as used at `peer_sync_service.dart:573-585`); `FileLibraryIndex`; the files account records in `sourceRecordsProvider`; the `filesBackendBuilderProvider` backend's `playable()`.
- Produces:
  - `class PeerFilesHost { Future<void> start(); void dispose(); Future<void> bumpRevision(String accountId); }`
  - `final peerFilesHostProvider = Provider<PeerFilesHost>`
  - `String? filesDedupeKey(FilesAccountRecord)`: `normalizeSmbUrl(url)` + share path for SMB, `normalizeWebDavUrl` for WebDAV, null for `flocal`. Task 6 also uses it.
  - `peer_files_wire.dart`: `List<Uint8List> encodeRecords<T>(Iterable<T>, Map Function(T))`, `List<T> decodeRecords<T>(List<Uint8List>, T Function(Map))`, `List<WireIndexPage> pageIndex(FileLibraryIndex, {int budget})`.

Behaviour that the tests pin:
- `start()` acts only while the device is in a group. On every `onStateChanged` it pushes the active, non-revoked member ids with `setPeerFilesMembers`, and it pushes `[]` after leaving the group.
- A `Manifest` or `IndexPage` whose proof is wrong, or whose sender is not a known, active member, gets `NotAuthorized`.
- `Manifest` lists every files account with `revision` (0 if none is stored) and `filesDedupeKey`.
- `IndexPage` with a `revision` that is not the current one gets `StaleRevision`. Otherwise it answers with records from `cursor` onward, up to `PEER_FILES_PAGE_BUDGET`. The cursor is the index of the next record across roots, then files, groups, movies and shows, as a decimal string. The last page has `next_cursor: null`.
- A grant request is accepted only if `path` equals some `IndexedFile.path` of that account or appears in some file's `sidecars`. Otherwise the answer is `null`, without calling the backend. On acceptance it answers with the URL and headers of `backend.playable(path)`. A `BackendFailure` answers `null`.
- `bumpRevision` increments, persists, and calls `invalidatePeerFileGrants(accountId)`.

- [ ] **Step 1: Write the failing tests**
  The tests use a fake `PeerFilesTransport`, an in-memory sync store, and an index of 3 roots and 2,000 invented files (titles like "The Copper Lantern").
  - `rejects_bad_proof`
  - `rejects_revoked_member`
  - `manifest_lists_accounts_with_revision_and_dedupe_key`: SMB key equals `normalizeSmbUrl`, `flocal` gives null.
  - `pages_stay_under_budget_and_cover_every_record`: use `budget: 64 * 1024` in the test. Concatenating every page's decoded records equals the index.
  - `stale_revision_when_scan_finishes_mid_fetch`: fetch page 1, `bumpRevision`, then fetch page 2 with the old revision and get `StaleRevision`.
  - `grant_refuses_path_outside_index` (`/etc/passwd`, `../x`, another account's file) and assert the backend is never called.
  - `grant_allows_sidecar_of_indexed_file`
  - `members_pushed_on_state_change_and_cleared_on_leave`
  - `bump_invalidates_rust_grants`
  - In `peer_files_wire_test.dart`, `records_round_trip` for each of the five record types.
- [ ] **Step 2: Run them and see them fail**
  Run: `./dev flutter test test/core/p2p/peer_files_host_test.dart test/core/p2p/peer_files_wire_test.dart`
- [ ] **Step 3: Implement the wire codec, the host, the revision box and the bump call sites**
- [ ] **Step 4: Run the tests and analyze**
  Run: the tests above, then `./dev flutter analyze`. Expected: PASS with no issues.
- [ ] **Step 5: Commit**
  `git commit -m "feat(player): answer PeerFiles manifest and index pages from the files index"`

---

### Task 6: `PeerFilesClient` and the replicated index store

**Files:**
- Create: `player/lib/core/p2p/peer_files_store.dart`
- Create: `player/lib/core/p2p/peer_files_client.dart`
- Modify: `kMydiaHiveBoxes` and `initAppHive()` (`'peer_files_index'`)
- Test: `player/test/core/p2p/peer_files_store_test.dart`, `player/test/core/p2p/peer_files_client_test.dart`

**Interfaces:**
- Consumes: `PeerFilesTransport` (Task 4), `peer_files_wire.dart` and `filesDedupeKey` (Task 5), `PeerSyncService` (members, `onStateChanged`, completed sync rounds), and the files account records.
- Produces:
  - `String peerFilesAccountId(String nodeId, String hostAccountId)`, which returns `'p${sha256(nodeId).hex.substring(0, 12)}_$hostAccountId'`.
  - `class PeerSharedAccount { final String nodeId; final String deviceName; final WireSharedAccount wire; String get localAccountId; }`
  - `class PeerFilesStore`:
    - `FileLibraryIndex index(String localAccountId)`, which is built over the current generation's prefix `'$localAccountId@$gen'`.
    - `Future<void> replace(String localAccountId, int revision, List<WireIndexPage> pages)`: writes generation `gen+1`, flips `meta/$localAccountId` to `{gen, revision}`, then deletes the old generation's keys.
    - `int? revision(String localAccountId)`
    - `Future<void> remove(String localAccountId)`
  - `class PeerFilesClient`:
    - `ValueListenable<List<PeerSharedAccount>> accounts`
    - `Future<void> refresh({String? nodeId})`
    - `Future<void> start()`, which refreshes on start, after each completed sync round with a member, and on `onStateChanged`.
    - `void dispose()`
  - `final peerFilesClientProvider`, `final peerFilesStoreProvider`.

Behaviour that the tests pin:
- `accounts` holds, for every active member, each manifest account except an SMB or WebDAV one whose `dedupe_key` equals `filesDedupeKey` of a local account. `flocal` is never skipped.
- An account whose revision equals the stored one is not fetched. A changed one is fetched page by page; on any failure the old index stays. `StaleRevision` re-reads the manifest and restarts, at most twice per refresh.
- When an account leaves the manifest, when its member is revoked, or when this device leaves the group, it is removed from `accounts` and from the store.
- An unreachable member keeps its last accounts and index.

- [ ] **Step 1: Write the failing tests**
  - Store: `replace_is_atomic`. Make the box throw on the 3rd write of the new generation; `index()` still returns the old records and `revision()` is unchanged. Also `replace_drops_old_generation` and `remove_deletes_everything`.
  - Client, with a fake transport and members `tv` and `desk`:
    - `builds_accounts_from_manifest`
    - `skips_peer_smb_matching_local_smb`
    - `never_skips_flocal`
    - `unchanged_revision_not_refetched` (asserts the call count)
    - `failed_page_keeps_old_index`
    - `stale_revision_restarts_at_most_twice`
    - `removed_on_manifest_drop_revocation_and_leave`
    - `offline_member_keeps_accounts`
    - `local_account_id_is_namespaced`: the host's `flocal` from two different nodes gives two distinct ids, neither equal to `flocal`.
- [ ] **Step 2: Run them and see them fail**
- [ ] **Step 3: Implement the store and the client**
- [ ] **Step 4: Run the tests and see them pass**
- [ ] **Step 5: Commit**
  `git commit -m "feat(player): replicate paired devices' files indexes"`

---

### Task 7: Peer sources, `PeerFilesBackend` and the proxy route

**Files:**
- Modify: `player/lib/core/p2p/media_route.dart`. Add `static String peerFile(String base, String accountId, String path)` giving `'$base/peerfile/$accountId/${base64UrlNoPad(utf8(path))}/stream'`, and a `resolve` branch through `_byteStream` with `prefix: '/peerfile/'`, `sessionPrefix: 'peerfile:'`, giving a route with session `peerfile:<accountId>` and `path: <token>`. Change `_byteStream` if needed so the token becomes the request path and not `'stream'`. If the browser's Service Worker table (`sw_protocol.dart`) mirrors the routes, leave `peerfile` out of it, since web never views.
- Create: `player/lib/core/p2p/peer_files_backend.dart`
- Modify: `player/lib/core/sources/files/files_media_source.dart`. Add a `String? syncAccountId` constructor parameter (default `source.account.id`) and use it at lines 107, 219, 379 and 476 in place of `source.account.id` wherever a sync key is built or parsed. Line 154 (`_isNetworkShare`) becomes true for peer sources.
- Modify: `player/lib/core/sources/files/files_providers.dart`. `buildFilesSource` takes an index and a backend from the peer store when the source is a peer source, skips `_scanIfDue` and the probe-and-rescan listener, and passes `syncAccountId`. `filesBackendBuilderProvider` returns `PeerFilesBackend` for peer sources.
- Modify: `player/lib/core/sources/sources_providers.dart`. `sourcesProvider` = stored sources + `peerFilesSourcesProvider`. Any screen that edits sources (rename, delete, rescan, Change address) checks `isPeerFilesSource(source)` and hides those actions.
- Create: `player/lib/core/sources/files/peer_files_sources.dart`
- Test: `player/test/core/p2p/media_route_peer_file_test.dart`, `player/test/core/p2p/peer_files_backend_test.dart`, `player/test/core/sources/files/peer_files_sources_test.dart`, `player/test/presentation/peer_files_source_widget_test.dart`

**Interfaces:**
- Consumes: `PeerFilesClient.accounts` and `PeerFilesStore.index` (Task 6), `PeerFilesTransport.openRangeStream` (Task 4), `LocalProxyService.start` and `targetBaseUrl` (`local_proxy_service.dart:130,616`).
- Produces:
  - `final peerFilesSourcesProvider = Provider<List<Source>>`. One `Source` per `PeerSharedAccount`: kind `files`, `account.id = localAccountId`, and the server name `'${deviceName} · ${wire.name}'`.
  - `bool isPeerFilesSource(Source)`, true when `account.id` matches `^p[0-9a-f]{12}_`.
  - `class PeerFilesBackend implements FileSystemBackend`, constructed with `{nodeId, hostAccountId, proxy, transport}`:
    - `playable(path)` starts proxy target `'peer_${nodeId.substring(0, 12)}'` for `targetPeer: nodeId` and probes with `openRangeStream(sessionId: 'peerfile:$hostAccountId', path: token, rangeStart: 0, rangeEnd: 0)`, then cancels the probe. Status 2xx returns `PlayableFile(url: MediaRoutes.peerFile(...))`. 404 throws `BackendNotFound`; 502 and a failed open throw `BackendUnreachable`; 403 throws `BackendUnauthorized`.
    - `list` and `stat` throw `BackendUnreachable('read-only peer library')`; `probe` succeeds when the peer is connected and throws `BackendUnreachable` otherwise.

- [ ] **Step 1: Write the failing tests**
  - Route round trip, `peer_file_route_round_trips`. For each of `'/media/A Film (2031)/a #1?.mkv'`, `r'C:\Movies\Žluť.mkv'` and `'/x/y z.srt'`: `MediaRoutes.resolve` of the path built by `peerFile` (minus base) gives session `peerfile:flocal` and a token that decodes back to the original.
  - `PeerFilesBackend` with `fake_range_stream.dart`:
    - `playable_returns_proxy_url_after_2xx_probe`
    - `probe_404_throws_not_found`
    - `probe_502_throws_unreachable`
    - `open_failure_throws_unreachable`
    - `probe_403_throws_unauthorized`
    - `list_and_stat_throw`
  - Sources:
    - `peer_sources_follow_client_accounts`
    - `peer_and_local_flocal_coexist`: both sources exist with distinct `SourceId`s, and each `FileLibraryIndex` sees only its own records.
    - `peer_source_uses_host_account_for_sync_keys`: marking an unmatched peer file watched writes `unmatchedFileSyncKey('flocal', key)` to the sync store.
    - `peer_source_never_scans`: `filesScanProvider` is never invoked.
    - `revoked_host_removes_sources`
  - Widget: `peer_source_renders_home_and_detail_from_replicated_index`. Seed the store with one invented movie, pump Home, tap the card, and find the title on the detail screen. A backend spy records zero `list` calls.
- [ ] **Step 2: Run them and see them fail**
- [ ] **Step 3: Implement the route, the backend, the sources provider, the `syncAccountId` threading and the hidden edit actions**
- [ ] **Step 4: Run the new tests plus the existing files-source suite**
  Run: `./dev flutter test test/core/p2p test/core/sources/files test/presentation/peer_files_source_widget_test.dart`
  Expected: PASS, with no regressions in the existing files tests.
- [ ] **Step 5: Commit**
  `git commit -m "feat(player): paired devices' files libraries appear and play as sources"`

---

### Task 8: Error copy, the unreachable status and the docs

**Files:**
- Modify: the files source's mapping from `BackendFailure` to `SourceException` in `files_media_source.dart`. When the source is a peer source, use the device-named messages below.
- Modify: `player/lib/l10n/app_en.arb` and the other ARBs per `player/docs/l10n.md`
- Modify: `player/lib/core/sources/current_source_status.dart` (a peer source is unreachable while its member is not connected and its last probe failed)
- Modify: `player/lib/core/sources/README.md` (a "Peer files sources" section: derivation, ids, dedupe, the read path, and why there is no scan) and `native/README.md` (the `peerfile:` session on `HlsStream`)
- Test: `player/test/core/sources/files/peer_files_errors_test.dart`

**Copy (exact, `{device}` is the member's device name):**
- `peerFilesHostUnreachable`: "{device} isn't reachable. It needs to be on with Mydia Player open."
- `peerFilesFileGone`: "This file is no longer on {device}."
- `peerFilesShareDown`: "{device} can't reach its share right now."

**Behaviour that the tests pin:**
- `BackendUnreachable` from a peer backend maps to `peerFilesHostUnreachable`, but to `peerFilesShareDown` when it came from a 502 (carry the status on the exception).
- `BackendNotFound` maps to `peerFilesFileGone` and calls `PeerFilesClient.refresh(nodeId:)`.
- `BackendUnauthorized` calls `refresh(nodeId:)`, which removes that host's sources once its manifest answers `NotAuthorized`.

- [ ] **Step 1: Write the failing tests**
  One test per mapping above, plus `unreachable_status_when_member_disconnected`.
- [ ] **Step 2: Run them and see them fail**
- [ ] **Step 3: Implement the copy, the mappings and the status, then write the docs**
- [ ] **Step 4: Run the tests and analyze; the l10n check must pass**
  Run: `./dev flutter test test/core/sources/files/peer_files_errors_test.dart && ./dev flutter analyze`
- [ ] **Step 5: Commit**
  `git commit -m "feat(player): device-named errors and status for peer files sources"`

---

### Task 9: Manual end-to-end check

- [ ] **Step 1: Pair two desktops on one LAN**
  Use `./dev player macos run`, or a Linux build on two machines. On machine A, add a local folder with one invented title, plus an SMB share.
- [ ] **Step 2: Check machine B**
  B shows "<A's name> · Folders" and the SMB library. Play a movie from each, seek near the end, and confirm watch state appears on A within one sync round.
- [ ] **Step 3: Check dedupe**
  Add the same SMB share directly on B. The peer copy disappears after the next refresh.
- [ ] **Step 4: Check casting**
  Cast a peer file from B to the Chromecast and confirm it plays.
- [ ] **Step 5: Check the relay**
  Block UDP between the machines (or use separate networks) so the connection is relayed. Playback starts, and the detail screen shows the via-relay badge.
- [ ] **Step 6: Check revocation and an offline host**
  Revoke B from A: B's peer sources disappear. Quit A and press Play on B: the unreachable message appears within a few seconds.
- [ ] **Step 7: Run the full checks**
  Run `mix precommit` and the player suite, and record the results in the PR body.
