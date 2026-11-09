# Peer-to-peer watch-state sync in the player: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the player pair directly with the viewer's other player devices over iroh P2P (with no Mydia server required) into a transitive sync group that synchronizes `FilesMediaSource` watch state, playback resume positions, and manual "Fix match" pins, and includes paired peers in the remote-control roster.

**Architecture:** `mydia_p2p_core` gains `MydiaRequest::PeerSync(PeerSyncRequest)` and `MydiaResponse::PeerSync(PeerSyncResponse)` (`Pair` and `Sync` messages), bridged to Dart via `mydia_player_p2p` alongside `PairingKeys::seal`. In Dart, `PeerGroupSecret` (32 bytes in `AuthStorage`) and `PeerSyncStore` (Hive box `peer_sync`) store the replicated `PeerGroupRoster`, unified LWW `PeerWatchRecord`s (`tmdb:*` across all files libraries and `file:<accountId>:<fileKey>` per share), and `PeerPinRecord`s (`pin:<m|s>:<groupKey>`). `PeerSyncService` drives pairing over `metadata-relay` `/pairing/v2/claim` or QR codes, runs one-round-trip push/pull `Sync` exchanges using monotonic local `landedAt` watermarks for transitive convergence, and invalidates affected `FilesMediaSource` caches.

**Tech Stack:** Rust (`mydia_p2p_core`, `mydia_player_p2p`, `serde`, `serde_cbor`), `flutter_rust_bridge =2.13.0`, Flutter/Riverpod, `hive_ce`, `crypto` (SHA-256 / HMAC-SHA256).

**Spec:** `design/specs/2026-11-08-player-p2p-watch-sync-design.md`

## Global Constraints

- Wire protocol compatibility: `MydiaRequest::PeerSync` and `MydiaResponse::PeerSync` are appended to the end of their enums in `mydia_p2p_core` and compile on both native and `wasm32-unknown-unknown`.
- All Rust crates obey `rust-lints.toml` (`scripts/check-rust-lints.sh` and `scripts/check-rust.sh` must pass). No `unwrap`/`expect`/`panic` outside test modules.
- Group identity: `groupSecret` is 32 random bytes stored as base64url (no padding) in `AuthStorage` at `peer_group/secret`. `groupId` is the first 16 lowercase hex chars of `SHA-256("mydia/peer-group/id/v1" || secretBytes)`.
- Request authentication: `authProof(senderNodeId)` is 64 lowercase hex chars of `HMAC-SHA256(secretBytes, utf8.encode("mydia/peer-group/auth/v1|$senderNodeId"))`, checked in constant time against the iroh-authenticated `peer` node ID.
- Canonical sync keys:
  - Matched movie: `tmdb:movie:<tmdbId>`
  - Matched episode: `tmdb:ep:<tmdbId>:<season>:<episode>`
  - Unmatched file: `file:<accountId>:<fileKey>`
  - Manual match pin: `pin:m:<groupKey>` (movie) or `pin:s:<groupKey>` (show)
- Clock-skew bound: any incoming `updatedAt` greater than `localNowMs + 60000` is clamped to `localNowMs + 60000` before comparison and storage.
- Local monotonic receipt watermark: every stored record has a local `landedAt` (`max(localNowMs, lastIssuedLandedAt + 1)`), and delta sync filters by `landedAt > sinceLandedMs` so records learned from a third peer while offline still propagate transitively.
- Hive box `peer_sync` must be added to `kMydiaHiveBoxes` in `player/lib/core/storage/hive_box_migration.dart` and opened in `openFilesLibraryBoxes()` (`player/lib/core/sources/files/files_providers.dart`).
- Every user-visible string goes through l10n in `app_en.arb`, `app_es.arb`, `app_pt.arb`, and `app_pt_BR.arb` (`test/l10n/untranslated_text_test.dart` checks all of `lib/`).
- No real movie or TV titles in tests or fixtures. Invent them (e.g., `Fable of Glass`, `Harbor of Echoes`).
- Commits: plain `git commit -F <msgfile>` with no AI attribution.

## Review Focus

1. **Cross-device unwatched resurrection:** Device A plays a movie to 95% (`positionSeconds / durationSeconds >= 0.90`, which counts as watched). Device B later marks it unwatched. After sync, Device A must show the movie as unwatched with no resume position (`positionSeconds: null`). Pinned by `unwatched_clears_ninety_five_percent_position` (Task 3).
2. **Three-peer offline transitive convergence:** Device A watches a movie at $t = 1000$ while offline. Device B and Device C sync at $t = 2000$. Device A comes online and syncs with Device B at $t = 3000$. When Device B and Device C sync at $t = 4000$, Device C must receive Device A's $t = 1000$ record because its `landedAt` on B is $3000 > 2000$. Pinned by `three_peer_offline_transitive_convergence` (Task 6).
3. **Transitive revocation blocks future sync and remote control:** Device C revokes Device A and syncs with Device B. When Device A later sends a `Sync` or `RemoteControl` request to Device B, Device B refuses it with `NotAuthorized`. Pinned by `revocation_propagates_and_blocks_peer` (Task 6).
4. **Cross-account TMDB state on the same device:** Marking a matched movie watched on one `FilesMediaSource` (e.g., `flocal`) immediately shows it watched on a second `FilesMediaSource` (e.g., an SMB share `s0123456789abcdef`) and invalidates both sources' caches. Pinned by `matched_watch_state_shared_across_files_sources` (Task 5).
5. **Brute-force bound on pairing code:** After 5 wrong `Pair` attempts against an active 6-character code, the host discards the code and refuses a 6th attempt even if it carries the previously valid code. Pinned by `expires_active_code_after_five_wrong_guesses` (Task 6).

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `native/mydia_p2p_core/src/peer_sync.rs` | Wire types: `PeerSyncRequest`, `PeerSyncResponse`, `WirePeerMember`, `WireWatchRecord`, `WirePinRecord` + CBOR round-trip tests |
| `native/mydia_p2p_core/src/lib.rs` | `MydiaRequest::PeerSync`, `MydiaResponse::PeerSync`, re-exports |
| `native/mydia_p2p_core/tests/two_node_peer_sync.rs` | Two-node loopback integration test for `PeerSync` and `pairing_seal` |
| `player/rust/mydia_player_p2p/src/lib.rs` | FRB mirror types (`FlutterPeerSync*`, `FlutterSealedClaim`), `peer_sync_stream`, `send_peer_sync`, `respond_to_peer_sync`, `PairingKeys::seal` |
| `player/lib/core/relay/relay_api_client.dart` | Add `publishClaimCode` (`POST /pairing/v2/claim`) and `deleteClaimCode` (`DELETE /pairing/v2/claim/:lookupKey`) |
| `player/lib/core/relay/pairing_key_handle.dart` | Add `seal(String nodeAddr, String instanceId)` to `PairingKeyHandle` |
| `player/lib/core/p2p/peer_group_secret.dart` | `PeerGroupSecret`: 32-byte secret generation, `AuthStorage` persistence, `groupId`, constant-time `authProof` verification |
| `player/lib/core/p2p/peer_sync_records.dart` | `PeerMember`, `PeerWatchRecord`, `PeerPinRecord`, `PeerWatermark`, canonical key builders (`tmdbMovieSyncKey`, `tmdbEpisodeSyncKey`, `unmatchedFileSyncKey`, `pinSyncKey`) |
| `player/lib/core/p2p/peer_sync_store.dart` | `PeerSyncStore` (`HivePeerSyncStore`, `InMemoryPeerSyncStore`): LWW merge, clock-skew clamp, monotonic `landedAt`, roster merge, seeding from `FileLibraryIndex` & `PlaybackProgressStore` |
| `player/lib/core/p2p/peer_group_roster.dart` | `PeerGroupRoster implements DeviceRoster` backed by `PeerSyncStore`, wired into `MergedRoster` |
| `player/lib/core/p2p/peer_sync_service.dart` | `PeerSyncService` & Riverpod providers: claim-code/QR pairing host & joiner, 1-RTT `Sync` push/pull, 60s peer cooldown, pin application & `FilesMediaSource` cache invalidation |
| `player/lib/core/sources/files/files_queries.dart` | Read matched & unmatched watch/progress state from `PeerSyncStore` |
| `player/lib/core/sources/files/files_media_source.dart` | Write `setWatched`, `removeFromContinueWatching`, and `setMatch` pins through `PeerSyncStore` + `PeerSyncService` |
| `player/lib/core/sources/files/match/file_matcher.dart` | Consult `PeerSyncStore` pins during scans and migrate provisional/file state into `PeerSyncStore` |
| `player/lib/presentation/screens/settings/paired_devices_screen.dart` | `PairedDevicesScreen` and `PairedDevicesBody`: show QR/6-char code, enter/scan code, peer list, remove peer, leave group, sync now |

---

### Task 1: `mydia_p2p_core` wire types and two-node loopback test

**Files:**
- Create: `native/mydia_p2p_core/src/peer_sync.rs`
- Modify: `native/mydia_p2p_core/src/lib.rs:60-155`
- Test: `native/mydia_p2p_core/tests/two_node_peer_sync.rs`

**Interfaces:**
- Produces (`native/mydia_p2p_core/src/peer_sync.rs`, re-exported from `mydia_p2p_core`):

```rust
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct WirePeerMember {
    pub node_id: String,
    pub device_name: String,
    pub platform: String,
    pub endpoint_addr_json: Option<String>,
    pub updated_at_ms: i64,
    pub revoked: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct WireWatchRecord {
    pub key: String,
    pub watched: bool,
    pub position_seconds: Option<i64>,
    pub duration_seconds: Option<i64>,
    pub updated_at_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct WirePinRecord {
    pub key: String,
    pub group_key: String,
    pub is_show: bool,
    pub tmdb_id: Option<i64>,
    pub pinned: bool,
    pub updated_at_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum PeerSyncRequest {
    Pair {
        claim_code: String,
        device_name: String,
        platform: String,
        endpoint_addr_json: Option<String>,
    },
    Sync {
        auth_proof: String,
        sender_endpoint_addr_json: Option<String>,
        roster: Vec<WirePeerMember>,
        since_landed_ms: i64,
        watch_records: Vec<WireWatchRecord>,
        pin_records: Vec<WirePinRecord>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum PeerSyncResponse {
    Paired {
        group_secret_base64: String,
        roster: Vec<WirePeerMember>,
        watch_records: Vec<WireWatchRecord>,
        pin_records: Vec<WirePinRecord>,
    },
    PairRejected {
        reason: String,
    },
    SyncAck {
        roster: Vec<WirePeerMember>,
        watch_records: Vec<WireWatchRecord>,
        pin_records: Vec<WirePinRecord>,
        peer_now_ms: i64,
    },
    NotAuthorized,
}
```

- Produces on `MydiaRequest` and `MydiaResponse` in `native/mydia_p2p_core/src/lib.rs`:
  - `MydiaRequest::PeerSync(PeerSyncRequest)`
  - `MydiaResponse::PeerSync(PeerSyncResponse)`

- [ ] **Step 1: Write the failing unit and loopback tests**

Create `native/mydia_p2p_core/tests/two_node_peer_sync.rs`:

```rust
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    reason = "integration test crate"
)]

use mydia_p2p_core::{
    Event, Host, HostConfig, MydiaRequest, MydiaResponse, PeerSyncRequest, PeerSyncResponse,
    WirePeerMember, WirePinRecord, WireWatchRecord,
};
use std::time::Duration;

const TEST_TIMEOUT: Duration = Duration::from_secs(60);

fn test_config() -> HostConfig {
    HostConfig {
        relay_urls: Vec::new(),
        bind_port: Some(0),
        keypair_path: None,
        keypair_bytes: None,
    }
}

#[tokio::test]
async fn two_hosts_exchange_peer_sync_messages() {
    tokio::time::timeout(TEST_TIMEOUT, async {
        let (responder, responder_id) = Host::new(test_config());
        let (dialer, dialer_id) = Host::new(test_config());

        let responder_addr = {
            let mut rx = responder.event_rx.lock().await;
            loop {
                if let Some(Event::Ready { node_addr }) = rx.recv().await {
                    break node_addr;
                }
            }
        };

        let responder_handle = tokio::spawn(async move {
            {
                let mut rx = responder.event_rx.lock().await;
                while let Some(event) = rx.recv().await {
                    if let Event::RequestReceived {
                        peer,
                        request: MydiaRequest::PeerSync(PeerSyncRequest::Sync { since_landed_ms, .. }),
                        request_id,
                    } = event
                    {
                        assert_eq!(peer, dialer_id);
                        assert_eq!(since_landed_ms, 100);
                        responder
                            .send_response(
                                request_id,
                                MydiaResponse::PeerSync(PeerSyncResponse::SyncAck {
                                    roster: vec![WirePeerMember {
                                        node_id: responder_id.clone(),
                                        device_name: "Living Room TV".into(),
                                        platform: "android".into(),
                                        endpoint_addr_json: None,
                                        updated_at_ms: 500,
                                        revoked: false,
                                    }],
                                    watch_records: vec![WireWatchRecord {
                                        key: "tmdb:movie:603".into(),
                                        watched: true,
                                        position_seconds: None,
                                        duration_seconds: Some(7200),
                                        updated_at_ms: 500,
                                    }],
                                    pin_records: vec![WirePinRecord {
                                        key: "pin:m:fable of glass:2031".into(),
                                        group_key: "fable of glass:2031".into(),
                                        is_show: false,
                                        tmdb_id: Some(603),
                                        pinned: true,
                                        updated_at_ms: 500,
                                    }],
                                    peer_now_ms: 600,
                                }),
                            )
                            .await
                            .unwrap();
                        break;
                    }
                }
            }
            responder
        });

        dialer.dial(responder_addr).await.unwrap();

        let response = dialer
            .send_request(
                responder_id,
                MydiaRequest::PeerSync(PeerSyncRequest::Sync {
                    auth_proof: "deadbeef".into(),
                    sender_endpoint_addr_json: None,
                    roster: vec![],
                    since_landed_ms: 100,
                    watch_records: vec![],
                    pin_records: vec![],
                }),
            )
            .await
            .unwrap();

        match response {
            MydiaResponse::PeerSync(PeerSyncResponse::SyncAck {
                watch_records,
                pin_records,
                peer_now_ms,
                ..
            }) => {
                assert_eq!(watch_records.len(), 1);
                assert_eq!(watch_records[0].key, "tmdb:movie:603");
                assert_eq!(pin_records.len(), 1);
                assert_eq!(peer_now_ms, 600);
            }
            other => panic!("unexpected response: {other:?}"),
        }

        let _responder = responder_handle.await.unwrap();
    })
    .await
    .unwrap();
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test --manifest-path native/mydia_p2p_core/Cargo.toml --test two_node_peer_sync`
Expected: FAIL (`unresolved import PeerSyncRequest`).

- [ ] **Step 3: Implement `peer_sync.rs` and wire into `native/mydia_p2p_core/src/lib.rs`**

Create `native/mydia_p2p_core/src/peer_sync.rs` with the structs/enums above and CBOR round-trip unit tests for `Pair`, `Sync`, `Paired`, `PairRejected`, `SyncAck`, and `NotAuthorized`. Export `pub mod peer_sync;` and `pub use peer_sync::*;` in `native/mydia_p2p_core/src/lib.rs`, and add `PeerSync(PeerSyncRequest)` to `MydiaRequest` and `PeerSync(PeerSyncResponse)` to `MydiaResponse`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test --manifest-path native/mydia_p2p_core/Cargo.toml`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add native/mydia_p2p_core/src/peer_sync.rs native/mydia_p2p_core/src/lib.rs native/mydia_p2p_core/tests/two_node_peer_sync.rs
git commit -m "feat(p2p): add PeerSync request and response wire types"
```

---

### Task 2: FRB bridge (`mydia_player_p2p`), `PairingKeys::seal`, `P2pService`, and `RelayApiClient`

**Files:**
- Modify: `player/rust/mydia_player_p2p/src/lib.rs`
- Generated: `player/rust/mydia_player_p2p/src/frb_generated.rs`, `player/lib/native/lib.dart`, `player/lib/native/frb_generated*.dart`
- Modify: `player/lib/core/relay/pairing_key_handle.dart`
- Modify: `player/lib/core/relay/relay_api_client.dart`
- Modify: `player/lib/core/p2p/p2p_service.dart`
- Test: `player/test/core/relay/relay_api_client_test.dart`, `player/test/core/p2p/p2p_service_peer_sync_test.dart`

**Interfaces:**
- Consumes: Task 1 (`PeerSyncRequest`, `PeerSyncResponse`, `WirePeerMember`, `WireWatchRecord`, `WirePinRecord`).
- Produces in `player/rust/mydia_player_p2p/src/lib.rs`:
  - `FlutterWirePeerMember`, `FlutterWireWatchRecord`, `FlutterWirePinRecord`
  - `FlutterPeerSyncRequest` (`Pair`, `Sync`), `FlutterPeerSyncResponse` (`Paired`, `PairRejected`, `SyncAck`, `NotAuthorized`)
  - `FlutterInboundPeerSyncRequest { pub peer: String, pub request_id: String, pub request: FlutterPeerSyncRequest }`
  - `FlutterSealedClaim { pub lookup_key: String, pub sealed: String }`
  - `PairingKeys::seal(&self, node_addr: String, instance_id: String) -> anyhow::Result<FlutterSealedClaim>`
  - `P2pHost::peer_sync_stream(&self, sink: StreamSink<FlutterInboundPeerSyncRequest>) -> anyhow::Result<()>`
  - `P2pHost::send_peer_sync(&self, peer: String, req: FlutterPeerSyncRequest) -> anyhow::Result<FlutterPeerSyncResponse>`
  - `P2pHost::respond_to_peer_sync(&self, request_id: String, res: FlutterPeerSyncResponse) -> anyhow::Result<()>`
- Produces in `player/lib/core/relay/pairing_key_handle.dart`:
  - `Future<({String lookupKey, String sealed})> seal(String nodeAddr, String instanceId)` on `PairingKeyHandle`
- Produces in `player/lib/core/relay/relay_api_client.dart`:
  - `Future<({String lookupKey, String sealed})> publishClaimCode({required String code, required String nodeAddr, required String instanceId})` (calls `keys.seal(nodeAddr, instanceId)` and `POST $baseUrl/pairing/v2/claim` with JSON `{"lookup_key": lookupKey, "sealed": sealed}`)
  - `Future<void> deleteClaimCode(String lookupKey)` (`DELETE $baseUrl/pairing/v2/claim/$lookupKey`)
- Produces in `player/lib/core/p2p/p2p_service.dart`:
  - `Stream<FlutterInboundPeerSyncRequest> get onPeerSyncRequest`
  - `Future<FlutterPeerSyncResponse> sendPeerSync(String peer, FlutterPeerSyncRequest request)`
  - `Future<void> respondToPeerSync(String requestId, FlutterPeerSyncResponse response)`

- [ ] **Step 1: Write the failing Rust dispatcher test and Dart `RelayApiClient` / `P2pService` tests**

In `player/rust/mydia_player_p2p/src/lib.rs` (test module), add a test verifying `run_event_dispatcher` routes `Event::RequestReceived` with `MydiaRequest::PeerSync` onto `peer_sync_tx` without blocking `generic_tx` when `peer_sync_tx` is full (32 slots), and a test that `PairingKeys::derive("K7RPM2").seal(addr, id)` opens back via `PairingKeys::derive("k7r-pm2").open(sealed)`.

In `player/test/core/relay/relay_api_client_test.dart`, add tests for `publishClaimCode` (`POST /pairing/v2/claim` sends `lookup_key` and `sealed`, throws `RateLimitedException` on 429) and `deleteClaimCode` (`DELETE /pairing/v2/claim/<lookupKey>`).

In `player/test/core/p2p/p2p_service_peer_sync_test.dart`, test that `debugAdoptNativeSubscriptions` subscribes and tears down `peerSync` alongside `events` and `control`.

- [ ] **Step 2: Run the tests to verify they fail**

Run:
- `cargo test --manifest-path player/rust/mydia_player_p2p/Cargo.toml`
- `./dev flutter test test/core/relay/relay_api_client_test.dart test/core/p2p/p2p_service_peer_sync_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement Rust bridge methods, regenerate FRB bindings, and implement Dart methods**

1. Add the `FlutterPeerSync*` and `FlutterSealedClaim` types, `peer_sync_rx` channel in `P2pHost`, `PairingKeys::seal`, and `P2pHost` methods in `player/rust/mydia_player_p2p/src/lib.rs`.
2. Regenerate FRB bindings from `player/` (`flutter_rust_bridge_codegen generate`).
3. Update `PairingKeyHandle` in `player/lib/core/relay/pairing_key_handle.dart`, `RelayApiClient` in `player/lib/core/relay/relay_api_client.dart`, and `P2pService` in `player/lib/core/p2p/p2p_service.dart`.

- [ ] **Step 4: Run Rust, wasm, and Dart tests**

Run:
- `cargo test --manifest-path player/rust/mydia_player_p2p/Cargo.toml`
- `cargo build --manifest-path player/rust/mydia_player_p2p/Cargo.toml --target wasm32-unknown-unknown`
- `./dev flutter test test/core/relay/relay_api_client_test.dart test/core/p2p/p2p_service_peer_sync_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add player/rust/mydia_player_p2p player/lib/native player/lib/core/relay player/lib/core/p2p player/test/core/relay player/test/core/p2p
git commit -m "feat(player): bridge PeerSync and PairingKeys.seal to Dart"
```

---

### Task 3: `PeerGroupSecret`, `PeerSyncRecords`, and `PeerSyncStore` (LWW state & roster storage)

**Files:**
- Create: `player/lib/core/p2p/peer_group_secret.dart`
- Create: `player/lib/core/p2p/peer_sync_records.dart`
- Create: `player/lib/core/p2p/peer_sync_store.dart`
- Modify: `player/lib/core/storage/hive_box_migration.dart` (add `'peer_sync'` to `kMydiaHiveBoxes`)
- Test: `player/test/core/p2p/peer_group_secret_test.dart`, `player/test/core/p2p/peer_sync_store_test.dart`, `player/test/core/storage/hive_box_migration_test.dart`

**Interfaces:**
- Produces in `player/lib/core/p2p/peer_group_secret.dart`:

```dart
class PeerGroupSecret {
  PeerGroupSecret.fromBytes(Uint8List bytes);
  factory PeerGroupSecret.generate([Random? random]);
  factory PeerGroupSecret.fromBase64Url(String encoded);

  static const storageKey = 'peer_group/secret';

  Uint8List get bytes;
  String toBase64Url();
  String get groupId; // 16 hex chars of SHA-256("mydia/peer-group/id/v1" || bytes)
  String authProof(String senderNodeId); // 64 hex chars of HMAC-SHA256
  bool verifyAuthProof({required String senderNodeId, required String proof});
}
```

- Produces in `player/lib/core/p2p/peer_sync_records.dart`:

```dart
String tmdbMovieSyncKey(int tmdbId) => 'tmdb:movie:$tmdbId';
String tmdbEpisodeSyncKey(int tmdbId, int season, int episode) =>
    'tmdb:ep:$tmdbId:$season:$episode';
String unmatchedFileSyncKey(String accountId, String fileKey) =>
    'file:$accountId:$fileKey';
String pinSyncKey({required bool isShow, required String groupKey}) =>
    'pin:${isShow ? 's' : 'm'}:$groupKey';

/// Returns the canonical sync key for an [externalId] in [accountId], or null
/// when [externalId] is a provisional `p<sha16>` key or unparseable.
String? syncKeyForFilesItem({
  required String accountId,
  required String externalId,
  required bool isEpisode,
});

class PeerMember {
  const PeerMember({
    required this.nodeId,
    required this.deviceName,
    required this.platform,
    this.endpointAddrJson,
    required this.updatedAt,
    this.revoked = false,
  });
  // toMap / fromMap / copyWith / toWire / fromWire
}

class PeerWatchRecord {
  const PeerWatchRecord({
    required this.key,
    required this.watched,
    this.positionSeconds,
    this.durationSeconds,
    required this.updatedAt,
    required this.landedAt,
  });
  // toMap / fromMap / toWire
}

class PeerPinRecord {
  const PeerPinRecord({
    required this.key,
    required this.groupKey,
    required this.isShow,
    this.tmdbId,
    required this.pinned,
    required this.updatedAt,
    required this.landedAt,
  });
  // toMap / fromMap / toWire
}

class PeerWatermark {
  const PeerWatermark({
    required this.lastSentLandedAt,
    required this.lastPeerNowMs,
    required this.lastSyncedAt,
  });
}
```

- Produces in `player/lib/core/p2p/peer_sync_store.dart`:

```dart
abstract class PeerSyncStore {
  static const boxName = 'peer_sync';

  // Roster
  Map<String, PeerMember> members();
  PeerMember? member(String nodeId);
  Future<bool> putMember(PeerMember member);
  Future<Set<String>> mergeRoster(Iterable<PeerMember> incoming, {required int nowMs});
  Future<void> clearRoster();

  // Watch & progress
  PeerWatchRecord? watchRecord(String key);
  Map<String, PeerWatchRecord> allWatchRecords();
  Future<PeerWatchRecord> setWatched(String key, bool watched, {required int nowMs});
  Future<PeerWatchRecord> removeFromContinueWatching(String key, {required int nowMs});
  Future<PeerWatchRecord> recordProgress(
    String key, {
    required int positionSeconds,
    required int durationSeconds,
    required double watchedFraction,
    required int nowMs,
  });

  // Pins
  PeerPinRecord? pinRecord({required bool isShow, required String groupKey});
  Map<String, PeerPinRecord> allPinRecords();
  Future<PeerPinRecord> setPin({
    required String groupKey,
    required bool isShow,
    required int? tmdbId,
    required bool pinned,
    required int nowMs,
  });

  // Wire delta & LWW merge
  List<PeerWatchRecord> watchRecordsSince(int landedAtExclusive);
  List<PeerPinRecord> pinRecordsSince(int landedAtExclusive);
  Future<({Set<String> changedWatchKeys, Set<String> changedPinKeys})> mergeRemote({
    required Iterable<WireWatchRecord> watchRecords,
    required Iterable<WirePinRecord> pinRecords,
    required int nowMs,
  });

  // Per-peer sync watermarks
  PeerWatermark? watermark(String nodeId);
  Future<void> setWatermark(String nodeId, PeerWatermark mark);

  // Initial seeding
  bool get isSeeded;
  Future<void> markSeeded();
}

class HivePeerSyncStore implements PeerSyncStore {
  HivePeerSyncStore(Box<Map<dynamic, dynamic>> box);
}

class InMemoryPeerSyncStore implements PeerSyncStore {}
```

- [ ] **Step 1: Write the failing unit tests**

Create `player/test/core/p2p/peer_group_secret_test.dart`:
- `generates_32_bytes_and_round_trips_base64url`
- `derives_deterministic_16_char_hex_group_id`
- `verifies_valid_auth_proof_and_rejects_wrong_node_or_tampered_proof`

Create `player/test/core/p2p/peer_sync_store_test.dart`:
- `unwatched_clears_ninety_five_percent_position`: `recordProgress` at 950/1000 sets `watched: true, positionSeconds: 950`; then `setWatched(key, false, nowMs: 2000)` sets `watched: false, positionSeconds: null, durationSeconds: null, updatedAt: 2000`.
- `remote_unwatched_beats_older_local_watched_position`: merging a remote `WireWatchRecord(watched: false, positionSeconds: null, updatedAtMs: 2000)` over a local `updatedAt: 1000` record overwrites it and returns `key` in `changedWatchKeys`.
- `stale_remote_record_is_ignored`: merging `updatedAtMs: 500` over local `updatedAt: 1000` leaves local unchanged and returns empty `changedWatchKeys`.
- `clamps_future_updated_at_to_now_plus_60s`: merging a remote record with `updatedAtMs: nowMs + 3_600_000` stores `updatedAt: nowMs + 60_000`, so a local write at `nowMs + 60_001` beats it.
- `landed_at_advances_monotonically_for_old_origin_timestamps`: a remote record with `updatedAtMs: 100` arriving at `nowMs: 5000` gets `landedAt: 5000` and is returned by `watchRecordsSince(4000)`.
- `roster_merge_prefers_higher_updated_at_and_revoked_on_tie`: merging `revoked: true, updatedAt: 1000` against `revoked: false, updatedAt: 1000` keeps `revoked: true`.
- `hive_store_persists_across_reopen`: writes watch, pin, roster, and watermark records to a temp Hive box, reconstructs `HivePeerSyncStore`, and reads them back synchronously.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./dev flutter test test/core/p2p/peer_group_secret_test.dart test/core/p2p/peer_sync_store_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement `peer_group_secret.dart`, `peer_sync_records.dart`, `peer_sync_store.dart`, and add `'peer_sync'` to `kMydiaHiveBoxes`**

Implement the three files and add `'peer_sync'` to `kMydiaHiveBoxes` in `player/lib/core/storage/hive_box_migration.dart`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./dev flutter test test/core/p2p/peer_group_secret_test.dart test/core/p2p/peer_sync_store_test.dart test/core/storage/hive_box_migration_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add player/lib/core/p2p/peer_group_secret.dart player/lib/core/p2p/peer_sync_records.dart player/lib/core/p2p/peer_sync_store.dart player/lib/core/storage/hive_box_migration.dart player/test/core/p2p/peer_group_secret_test.dart player/test/core/p2p/peer_sync_store_test.dart
git commit -m "feat(player): add LWW PeerSyncStore and PeerGroupSecret"
```

---

### Task 4: `PeerGroupRoster` and `MergedRoster` integration

**Files:**
- Create: `player/lib/core/p2p/peer_group_roster.dart`
- Modify: `player/lib/core/remote/merged_roster.dart`
- Test: `player/test/core/p2p/peer_group_roster_test.dart`, `player/test/core/remote/merged_roster_test.dart`

**Interfaces:**
- Consumes: `PeerSyncStore`, `PeerMember` (Task 3), `DeviceRoster`, `RemoteDeviceEntry` (`player/lib/core/remote/remote_roster.dart`).
- Produces in `player/lib/core/p2p/peer_group_roster.dart`:

```dart
class PeerGroupRoster implements DeviceRoster {
  PeerGroupRoster({
    required PeerSyncStore store,
    required String? Function() localNodeId,
    required bool Function(String nodeId) isPeerConnected,
  });

  List<PeerMember> activeMembers();
}
```

- Modifies `MergedRoster` in `player/lib/core/remote/merged_roster.dart`:
  - `MergedRoster(Map<SourceId, DeviceRoster> rosters, {List<DeviceRoster> extras = const []})`
  - `entries()`, `onlineEntries()`, and `allows(String peerNodeId)` include `extras` (deduplicated by lowercase `nodeId`); `instancesOf(String nodeId)` stays scoped to the server `_rosters` map.
  - `operator ==` and `hashCode` compare `_extras` by `identical` alongside `_rosters`.

- [ ] **Step 1: Write the failing unit tests**

Create `player/test/core/p2p/peer_group_roster_test.dart`:
- `excludes_local_node_id_and_revoked_members_from_entries`
- `allows_active_member_and_refuses_revoked_or_unknown_node`
- `online_entries_returns_connected_active_members_or_all_active_when_none_connected`

Update `player/test/core/remote/merged_roster_test.dart`:
- `includes_extra_peer_group_roster_in_entries_and_allows_without_any_mydia_server`
- `deduplicates_device_present_in_both_server_roster_and_peer_group_roster`

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./dev flutter test test/core/p2p/peer_group_roster_test.dart test/core/remote/merged_roster_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement `peer_group_roster.dart` and update `merged_roster.dart`**

Implement `PeerGroupRoster` and add `extras` to `MergedRoster`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./dev flutter test test/core/p2p/peer_group_roster_test.dart test/core/remote/merged_roster_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add player/lib/core/p2p/peer_group_roster.dart player/lib/core/remote/merged_roster.dart player/test/core/p2p/peer_group_roster_test.dart player/test/core/remote/merged_roster_test.dart
git commit -m "feat(player): integrate PeerGroupRoster into MergedRoster"
```

---

### Task 5: `FilesMediaSource`, `FilesCatalog`, `FileMatcher`, and initial seeding integration

**Files:**
- Modify: `player/lib/core/sources/files/files_providers.dart`
- Modify: `player/lib/core/sources/files/files_queries.dart`
- Modify: `player/lib/core/sources/files/files_media_source.dart`
- Modify: `player/lib/core/sources/files/match/file_matcher.dart`
- Modify: `player/lib/core/player/local_progress_reporter.dart`
- Modify: `player/lib/presentation/screens/player/session/files_playback_session.dart`
- Test: `player/test/core/sources/files/files_peer_sync_integration_test.dart`

**Interfaces:**
- Consumes: `PeerSyncStore`, `syncKeyForFilesItem`, `pinSyncKey` (Task 3).
- Produces:
  - `openFilesLibraryBoxes()` in `files_providers.dart` also opens `Hive.openBox<Map<dynamic, dynamic>>(PeerSyncStore.boxName)` and runs `seedPeerSyncStoreIfNeeded(syncStore: ..., indexBox: ..., progressStore: ...)`.
  - `peerSyncStoreProvider` in `files_providers.dart` (or re-exported from `core/p2p/`): synchronous `Provider<PeerSyncStore>` backed by the open `peer_sync` box.
  - `FilesMediaSource`, `FilesCatalog`, and `FileMatcher` accept an optional `PeerSyncStore? syncStore` (wired by `buildFilesSource` in `files_providers.dart`) and an optional `void Function()? onSyncMutation` callback:
    - When `syncStore` is provided:
      - `FilesCatalog.watched(id)` and `progressOf(id)` read from `syncStore` for matched (`tmdb:*`) and unmatched (`file:<accountId>:<fileKey>`) items, falling back to `index.watched()` and `_progress` only for provisional `p<sha16>` items.
      - `FilesMediaSource.setWatched(ref, watched)` writes to `syncStore.setWatched(syncKey, watched, nowMs: ...)` (as well as `index.setWatched` / `_progress.delete` for provisional items), invalidates `SourceRules.watchedChanged` on all local `FilesMediaSource`s when a `tmdb:*` key changes, and triggers `onSyncMutation`.
      - `FilesMediaSource.removeFromContinueWatching(ref)` calls `syncStore.removeFromContinueWatching(syncKey, nowMs: ...)` and triggers `onSyncMutation`.
      - `FilesMediaSource.continueWatching()` merges `syncStore.allWatchRecords()` for items present in the catalog alongside provisional records in `_progress`.
      - `FileMatcher.pin(groupKey, isShow:, tmdbId:)` records `syncStore.setPin(groupKey: groupKey, isShow: isShow, tmdbId: tmdbId, pinned: true, nowMs: ...)` and triggers `onSyncMutation`.
      - During `FileMatcher.matchPending()`, if `syncStore.pinRecord(isShow: g.isShow, groupKey: g.key)` is `pinned == true` and newer than `index.group(g.key)?.matchedAt`, `FileMatcher` applies that pin (fetching TMDB metadata for `tmdbId` if non-null) without running a TMDB search.
      - `FileMatcher._migrateProgress` and `_migrateToFiles` also migrate any `file:<accountId>:<fileKey>` records in `syncStore` to/from the resolved `tmdb:*` key in `syncStore`.
      - `LocalProgressReporter` accepts an optional `PeerSyncStore? syncStore` + `String? Function(ItemRef) syncKeyFor` + `void Function()? onSyncWrite` so playback ticks and stop events write directly to `syncStore.recordProgress(...)`.

- [ ] **Step 1: Write the failing integration tests**

Create `player/test/core/sources/files/files_peer_sync_integration_test.dart`:
- `seeds_existing_watched_progress_and_pins_on_first_open`: populates `FileLibraryIndex` (watched movie `603`, pinned group `fable of glass:2031` → `603`) and `InMemoryPlaybackProgressStore` (episode `1399-1-1` at 120s/1800s), runs `seedPeerSyncStoreIfNeeded`, and verifies `PeerSyncStore` holds `tmdb:movie:603`, `tmdb:ep:1399:1:1`, and `pin:m:fable of glass:2031`.
- `matched_watch_state_shared_across_files_sources`: builds two `FilesMediaSource` instances (`flocal:owner:local` and `s0123456789abcdef:owner:s0123456789abcdef`) sharing one `InMemoryPeerSyncStore`, both indexing a file matched to TMDB movie `603` ("Fable of Glass"). Calling `setWatched(movie603, true)` on `flocal` immediately makes `s0123456789abcdef` report `userState.watched == true` and invalidates both sources.
- `remove_from_continue_watching_clears_synced_position_across_sources`: records a 300s/3600s position for `603`, verifies it appears in `continueWatching()`, calls `removeFromContinueWatching`, and verifies `continueWatching()` is empty on both sources.
- `matcher_applies_synced_pin_from_peer_sync_store_on_scan`: pre-populates `syncStore.setPin(groupKey: 'fable of glass:2031', isShow: false, tmdbId: 603, pinned: true, nowMs: 5000)`, runs `matcher.matchPending()`, and verifies `index.group('fable of glass:2031')` is pinned to `603` without calling `tmdb.searchMovies`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./dev flutter test test/core/sources/files/files_peer_sync_integration_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement `PeerSyncStore` integration in `files_providers.dart`, `files_queries.dart`, `files_media_source.dart`, `file_matcher.dart`, `local_progress_reporter.dart`, and `files_playback_session.dart`**

Wire `PeerSyncStore` through `FilesCatalog`, `FilesMediaSource`, `FileMatcher`, and `LocalProgressReporter` while keeping all existing `files` unit tests green when `syncStore` is omitted or empty.

- [ ] **Step 4: Run all files source tests to verify they pass**

Run: `./dev flutter test test/core/sources/files`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add player/lib/core/sources/files player/lib/core/player/local_progress_reporter.dart player/lib/presentation/screens/player/session/files_playback_session.dart player/test/core/sources/files/files_peer_sync_integration_test.dart
git commit -m "feat(player): route FilesMediaSource watch state, progress, and pins through PeerSyncStore"
```

---

### Task 6: `PeerSyncService` (pairing handshake, 1-RTT transitive sync, cooldowns, and pin application)

**Files:**
- Create: `player/lib/core/p2p/peer_sync_service.dart`
- Modify: `player/lib/core/sources/files/files_providers.dart` (connect `onSyncMutation` to `peerSyncServiceProvider`)
- Modify: `player/lib/core/remote/merged_roster.dart` (include `peerGroupRosterProvider` in `mergedRosterProvider`)
- Modify: `player/lib/app.dart` (ensure `peerSyncServiceProvider` is initialized at startup alongside `nodeRegistrationsProvider`)
- Test: `player/test/core/p2p/peer_sync_service_test.dart`

**Interfaces:**
- Consumes: Tasks 2, 3, 4, and 5.
- Produces in `player/lib/core/p2p/peer_sync_service.dart`:

```dart
abstract interface class PeerSyncTransport {
  String? get nodeId;
  String? get nodeAddr;
  Stream<FlutterInboundPeerSyncRequest> get onPeerSyncRequest;
  Stream<String> get onPeerConnected;
  Future<void> initialize();
  Future<String?> getNodeAddr();
  Future<void> dial(String endpointAddrJson);
  Future<void> addAddressHint(String endpointAddrJson);
  Future<FlutterPeerSyncResponse> sendPeerSync(String peer, FlutterPeerSyncRequest req);
  Future<void> respondToPeerSync(String requestId, FlutterPeerSyncResponse res);
  bool isConnectedToPeer(String peer);
}

class ActivePairingOffer {
  const ActivePairingOffer({
    required this.code,
    required this.qrJson,
    required this.lookupKey,
    required this.expiresAt,
  });
  final String code;
  final String qrJson;
  final String lookupKey;
  final DateTime expiresAt;
}

class PeerSyncService {
  PeerSyncService({
    required PeerSyncStore store,
    required AuthStorage authStorage,
    required PeerSyncTransport transport,
    required RelayApiClient relayClient,
    required String deviceName,
    required String platform,
    Future<void> Function(Set<String> changedWatchKeys, Set<String> changedPinKeys)? onRemoteChangesApplied,
    void Function(PeerMember joinedPeer)? onPeerPaired,
    DateTime Function()? clock,
  });

  bool get isPaired;
  String? get groupId;
  ActivePairingOffer? get activeOffer;
  Stream<void> get onStateChanged;

  Future<void> start();
  Future<ActivePairingOffer> startPairingOffer();
  Future<void> cancelPairingOffer();
  Future<void> pairWithCode(String code);
  Future<void> pairWithQr(String qrJson);
  Future<void> syncAll({bool ignoreCooldown = false});
  Future<void> notifyLocalMutation({bool throttle = false});
  Future<void> revokePeer(String nodeId);
  Future<void> leaveGroup();
  void dispose();
}

final peerSyncServiceProvider = Provider<PeerSyncService>((ref) => ...);
final peerGroupRosterProvider = Provider<PeerGroupRoster>((ref) => ...);
```

- [ ] **Step 1: Write the failing unit and mesh simulation tests**

Create `player/test/core/p2p/peer_sync_service_test.dart` using an in-memory `FakePeerSyncNetwork` that connects multiple `PeerSyncService` instances in memory:
- `pairs_two_devices_via_claim_code_and_merges_initial_state`: Device A has `tmdb:movie:603` watched; Device B has `tmdb:ep:1399:1:1` in progress. Device A calls `startPairingOffer()`, Device B calls `pairWithCode(offer.code)`. Afterward, both devices share the same `groupId`, list each other in `store.members()`, and both hold `tmdb:movie:603` and `tmdb:ep:1399:1:1`.
- `expires_active_code_after_five_wrong_guesses`: 5 `Pair` requests with a wrong code return `PairRejected`; the 6th request with the originally valid code also returns `PairRejected`.
- `three_peer_offline_transitive_convergence`:
  - Pair A ↔ B, then pair B ↔ C (so A, B, C are in one group; C learns A's member entry from B).
  - Disconnect A from the fake network.
  - At $t = 1000$, A marks `tmdb:movie:603` watched locally.
  - At $t = 2000$, B and C run `syncAll()`.
  - At $t = 3000$, reconnect A; A syncs with B (while C is disconnected).
  - At $t = 4000$, disconnect A, reconnect C, and run `B.syncAll()`.
  - Verify C now has `tmdb:movie:603` watched with `updatedAt == 1000`.
- `revocation_propagates_and_blocks_peer`:
  - With A, B, C paired, C calls `revokePeer(nodeA)` and syncs with B.
  - Verify B marks A as `revoked: true`.
  - When A sends `Sync` to B, B replies `NotAuthorized` and ignores A's records.
- `unreachable_peer_enters_60s_cooldown_until_cleared`:
  - When dialing Peer B fails, a second `notifyLocalMutation()` within 60s does not dial B again; advancing the clock past 60s or calling `syncAll(ignoreCooldown: true)` dials B again.
- `leave_group_revokes_self_clears_secret_and_keeps_local_watch_records`:
  - Calling `A.leaveGroup()` notifies B (so B sees A as `revoked: true`), deletes `peer_group/secret` on A, clears A's roster, and leaves A's `watchRecords` intact.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./dev flutter test test/core/p2p/peer_sync_service_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement `PeerSyncService`, providers, pin application callback, and `MergedRoster` wiring**

1. Implement `PeerSyncService` in `player/lib/core/p2p/peer_sync_service.dart`.
2. In `peerSyncServiceProvider`, wire `onRemoteChangesApplied`:
   - When `changedPinKeys` is non-empty, iterate over active `FilesMediaSource` instances, apply each changed `PeerPinRecord` to any `FileLibraryIndex` that has files for that `groupKey` (calling `matcher.pin` or unpinning + invalidating `FilesMediaSource.groupLandedTargets(sourceId)`).
   - When `changedWatchKeys` is non-empty, invalidate `SourceRules.watchedChanged(sourceId)` for each active `FilesMediaSource`.
3. Subscribe `PeerSyncService` to `connectionRefreshBusProvider` (calling `syncAll(ignoreCooldown: true)`) and start it from `app.dart`.
4. Include `ref.watch(peerGroupRosterProvider)` in `mergedRosterProvider` (`player/lib/core/remote/merged_roster.dart`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `./dev flutter test test/core/p2p/peer_sync_service_test.dart test/core/remote/merged_roster_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add player/lib/core/p2p/peer_sync_service.dart player/lib/core/sources/files/files_providers.dart player/lib/core/remote/merged_roster.dart player/lib/app.dart player/test/core/p2p/peer_sync_service_test.dart
git commit -m "feat(player): add PeerSyncService for P2P pairing and transitive watch-state sync"
```

---

### Task 7: Paired Devices Settings UI, routing, and l10n

**Files:**
- Create: `player/lib/presentation/screens/settings/paired_devices_screen.dart`
- Modify: `player/lib/presentation/screens/settings/settings_nav.dart` (add `openPairedDevices()`)
- Modify: `player/lib/presentation/screens/settings/dialog/settings_panes.dart` (push `PairedDevicesBody` in `DialogSettingsNav.openPairedDevices()` and include the Paired Devices row in the desktop dialog)
- Modify: `player/lib/presentation/screens/settings/widgets/settings_sections.dart` (add `pairedDevicesRow` to `ManageSettingsSection` and `PlaybackSettingsSection` when `includeRemoteControl` is true)
- Modify: `player/lib/core/router/app_router.dart` (add `/settings/paired-devices` route)
- Modify: `player/lib/l10n/app_en.arb`, `player/lib/l10n/app_es.arb`, `player/lib/l10n/app_pt.arb`, `player/lib/l10n/app_pt_BR.arb`
- Test: `player/test/presentation/screens/settings/paired_devices_screen_test.dart`, `player/test/l10n/untranslated_text_test.dart`

**Interfaces:**
- Consumes: `peerSyncServiceProvider`, `peerGroupRosterProvider`, `peerSyncStoreProvider` (Task 6).
- Produces:
  - `SettingsNav.openPairedDevices()` (`RouterSettingsNav` pushes `/settings/paired-devices`; `DialogSettingsNav` pushes a `SettingsPane` with `PairedDevicesBody` onto the playback/servers navigator).
  - `SettingsRow.navigation(key: const Key('paired-devices-row'), ...)` showing the count of active paired devices (or "Not paired").
  - `PairedDevicesScreen` and `PairedDevicesBody`:
    - `Key('pair-show-code-button')`: starts an offer via `startPairingOffer()` and displays the formatted code (`ABC-123`) in `Key('pair-active-code')` plus a QR code widget (`QrImageView` or custom QR painter if already in repo; check existing QR rendering in `lib/`) and a cancel button. When `onPeerPaired` fires, shows a toast and closes the offer card.
    - `Key('pair-code-input')` and `Key('pair-submit-code-button')`: text input for a 6-character code, calling `pairWithCode`.
    - `Key('pair-scan-qr-button')` (shown on mobile platforms): opens a `MobileScanner` sheet and calls `pairWithQr`.
    - One row per active `PeerMember` (`Key('paired-device-${member.nodeId}')`) showing `deviceName`, platform icon, connection/sync status subtitle, and a remove icon button (`Key('remove-peer-${member.nodeId}')`) that calls `revokePeer(member.nodeId)`.
    - When `isPaired` is true: `Key('paired-sync-now-button')` calling `syncAll(ignoreCooldown: true)` and `Key('paired-leave-group-button')` confirming and calling `leaveGroup()`.

- [ ] **Step 1: Write the failing widget tests**

Create `player/test/presentation/screens/settings/paired_devices_screen_test.dart`:
- `shows_empty_state_and_generates_six_char_pairing_code`
- `submitting_claim_code_pairs_and_lists_peer_device`
- `removing_a_peer_marks_it_revoked_and_hides_its_row`
- `leaving_group_clears_paired_state_after_confirmation`
- `settings_row_shows_paired_count_and_navigates_to_paired_devices`

- [ ] **Step 2: Run the test to verify it fails**

Run: `./dev flutter test test/presentation/screens/settings/paired_devices_screen_test.dart`
Expected: FAIL.

- [ ] **Step 3: Add ARB strings, regenerate l10n, and implement `PairedDevicesScreen` & settings navigation**

1. Add the new ARB strings to `app_en.arb`, `app_es.arb`, `app_pt.arb`, and `app_pt_BR.arb` and run `./dev flutter gen-l10n`.
2. Implement `PairedDevicesScreen` / `PairedDevicesBody`, `SettingsNav.openPairedDevices()`, `/settings/paired-devices` in `app_router.dart`, and the row in `settings_sections.dart`.

- [ ] **Step 4: Run widget tests, l10n checks, and `flutter analyze`**

Run:
- `./dev flutter test test/presentation/screens/settings/paired_devices_screen_test.dart test/l10n/untranslated_text_test.dart`
- `./dev flutter analyze`
Expected: PASS, 0 issues.

- [ ] **Step 5: Commit**

```bash
git add player/lib/presentation/screens/settings player/lib/core/router/app_router.dart player/lib/l10n player/test/presentation/screens/settings/paired_devices_screen_test.dart
git commit -m "feat(player): add Paired Devices settings screen for P2P sync"
```

---

### Task 8: Documentation and full suite verification

**Files:**
- Modify: `player/lib/core/sources/README.md` (document P2P watch-state and match-pin sync under `Files libraries` and `PeerGroupRoster` under `Mydia players`)
- Modify: `design/specs/2026-11-08-player-p2p-watch-sync-design.md` (if any symbol names shifted during implementation)

- [ ] **Step 1: Update `player/lib/core/sources/README.md`**

Add a short subsection under `## Files libraries` describing `PeerSyncStore`, `PeerSyncService`, and how `tmdb:*`, `file:<accountId>:<fileKey>`, and `pin:<m|s>:<groupKey>` sync across paired players, and note `PeerGroupRoster` in `MergedRoster`.

- [ ] **Step 2: Run the full verification suite**

Run:
- `scripts/check-rust-lints.sh`
- `scripts/check-rust.sh`
- `./dev flutter analyze`
- `./dev flutter test`
Expected: All pass with zero warnings or errors.

- [ ] **Step 3: Commit**

```bash
git add design/specs/2026-11-08-player-p2p-watch-sync-design.md design/plans/2026-11-08-player-p2p-watch-sync.md player/lib/core/sources/README.md
git commit -m "docs(player): document P2P peer pairing and watch-state sync"
```
