# SMB shares in the player's files library: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the player add an SMB2/3 share (found by mDNS or typed in) as a files library that scans, matches and plays like a WebDAV share.

**Architecture:** A new pure-Rust crate `player/rust/mydia_smb` holds the SMB client pool and a loopback HTTP range server. `mydia_player_p2p` exposes it to Dart through flutter_rust_bridge, with wasm stubs. In Dart, `SmbBackend` implements the existing `FileSystemBackend`, so the scanner, matcher, index and playback session are unchanged. New pieces: accounts, bonsoir discovery, an SMB add screen, and heal-on-resume.

**Tech Stack:** Rust (tokio, `smb` or `smb2` crate chosen in Task 1, hyper 1.x for the loopback server), flutter_rust_bridge 2.13.0, Flutter/Riverpod, bonsoir 7.

**Spec:** `design/specs/2026-11-07-player-smb-files-design.md`

## Global Constraints

- SMB 2.x and 3.x only. An SMB1-only server reports `Smb1Only` and the user sees: "This server only speaks SMB1, which the player doesn't support. Turn on SMB2 or later in its settings."
- No libsmbclient, no GPL code. Pure Rust only.
- The SMB code compiles on native targets only. On `wasm32`, every FRB function exists and returns an `Unsupported` error. The web build must keep building (`cargo build --target wasm32-unknown-unknown` on `mydia_player_p2p`).
- The loopback server binds `127.0.0.1:0`. URLs are `http://127.0.0.1:<port>/smb/<token>`, where the token is 128 random bits rendered as 32 lowercase hex characters. No path or credential is ever in a URL.
- Tokens expire after 12 hours unused. Pooled SMB connections close after 60 seconds idle.
- Account id: `s` followed by the first 16 hex characters of SHA-256 over `normalizeSmbUrl`. Normalized form: `smb://<host lowercased>[:port when not 445]/<share lowercased>`. IPv6 hosts keep their brackets.
- `SmbCredentials` JSON is `{"user","password","domain"}`, with `domain` nullable. An empty `user` means guest.
- Every user-visible string goes through l10n in `app_en.arb`, `app_es.arb`, `app_pt.arb` and `app_pt_BR.arb`. "SMB" is a protocol name: `// l10n-ignore: protocol name`, like WebDAV.
- The SMB entry carries `ExperimentalTitle`.
- Rust lints come from `rust-lints.toml` (copy the `[lints]` tables verbatim; `scripts/check-rust-lints.sh` checks them). No `unwrap`/`expect` outside tests.
- No real movie or TV titles in tests or fixtures. Invent them.
- Commits: plain `git commit -F <msgfile>` with the devenv hooks installed. Verify each one with `git show --stat`. No AI attribution.

## Review Focus

1. **Seek far into a large file:** mpv asks for `Range: bytes=<near end>-` immediately (MKV cues, MP4 `moov` at the tail). The server must answer 206 with only that range, without reading from offset 0. Pinned by `tail_range_reads_only_the_tail` (Task 3).
2. **Filenames with spaces, `#`, `%`, `?` or non-ASCII:** they must list, stat and play. The path never enters the URL, so only list and stat can break. Pinned by `lists_and_stats_awkward_names` (Task 2).
3. **mpv drops a connection mid-response (seek), then opens another:** the server must not leak the SMB file handle, and the next request must work. Pinned by `abandoned_response_does_not_poison_next_request` (Task 3).
4. **Listing a share with a folder the user can't read:** that entry comes back `unreadable` and the listing succeeds. Pinned by `denied_entry_is_unreadable_not_fatal` (Task 2).
5. **The same server typed as `NAS.local`, `nas.local:445`, `smb://nas.local/Media/`:** one account, not three. Pinned by `normalizes_equivalent_addresses` (Task 6).

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `player/rust/mydia_smb/Cargo.toml` | New crate; native-only deps (picked SMB crate, tokio, hyper, hyper-util, rand, hex, thiserror) |
| `player/rust/mydia_smb/src/lib.rs` | Public types: `SmbTarget`, `SmbCredentials`, `SmbEntry`, `SmbError`, `Heal` |
| `player/rust/mydia_smb/src/client.rs` | `SmbClient`: pool, list, stat, probe, list_shares, ranged read, error mapping |
| `player/rust/mydia_smb/src/range.rs` | `parse_range` (pure) |
| `player/rust/mydia_smb/src/stream.rs` | `StreamServer`: tokens, HTTP GET/HEAD with Range, reconnect-once, expiry, heal |
| `player/rust/mydia_smb/tests/samba/run-samba.sh` | Starts a throwaway Samba with a guest and an auth share; prints `export` lines |
| `player/rust/mydia_smb/tests/integration.rs` | Tests against that Samba; skipped unless `MYDIA_SMB_TEST_HOST` is set |
| `player/rust/mydia_player_p2p/src/smb.rs` | FRB surface plus wasm stubs |
| `player/lib/native/smb.dart` (generated) | FRB Dart bindings |
| `player/lib/core/sources/files/smb_native.dart` | `SmbNative` interface, FFI impl, `smbNativeProvider`, error mapping, heals stream |
| `player/lib/core/sources/files/backend/smb_backend.dart` | `SmbBackend`, `LazySmbBackend` |
| `player/lib/core/sources/files/smb_discovery.dart` | `SmbDiscovery` over bonsoir |
| `player/lib/presentation/widgets/files/remote_folder_picker.dart` | Folder browser extracted from the WebDAV screen and shared with SMB |
| `player/lib/presentation/screens/sources/add_smb_screen.dart` | SMB add and re-login flow |

---

### Task 1: Crate, Samba harness, CI, and the crate spike

**Files:**
- Create: `player/rust/mydia_smb/Cargo.toml`, `src/lib.rs`, `tests/samba/run-samba.sh`, `tests/integration.rs`
- Modify: `.github/workflows/ci.yml` (Rust job, after "Media names tests")
- Modify: this plan, filling in "Spike result" below

**Interfaces:**
- Produces: `run-samba.sh` exports `MYDIA_SMB_TEST_HOST=127.0.0.1`, `MYDIA_SMB_TEST_PORT=4455`, `MYDIA_SMB_TEST_USER=mydia`, `MYDIA_SMB_TEST_PASSWORD=mydia-test`. Shares: `guest` (guest ok, read-only), `auth` (user `mydia` only), `enc` (user `mydia`, `smb encrypt = required`), `smb1` (on a second smbd on port 4456 with `server max protocol = NT1`), and `auth/denied/`, a folder mode 000. Fixtures under the shares: `Fable of Glass (2031)/Fable of Glass (2031).mkv` (64 MiB of deterministic bytes: byte `i` = `(i * 31 + 7) % 251`), plus `Odd #1 50% ?é.mkv` (1 KiB).
- Produces: `fn test_env() -> Option<TestEnv>` in `tests/integration.rs`. It returns `None` (the test prints "skipped" and passes) when `MYDIA_SMB_TEST_HOST` is unset.

- [ ] **Step 1:** Write `run-samba.sh`. It generates `smb.conf` and the fixtures in `mktemp -d`, takes `smbd` from PATH (falling back to `nix shell nixpkgs#samba --command`), creates user `mydia` with `smbpasswd -c <conf> -a -s`, starts `sudo smbd --foreground --no-process-group -s <conf>` in the background, waits until port 4455 accepts, and prints the export lines. `stop` as the first argument kills it.
- [ ] **Step 2:** Write the spike as `tests/integration.rs::spike_throughput_and_seek` (`#[ignore]`). For each candidate crate behind a cargo feature (`spike-smb`, `spike-smb2`), it reads the 64 MiB fixture sequentially, then 20 random 1 MiB ranges, and prints MiB/s and median time to the first byte.
- [ ] **Step 3:** Run it with both features against the harness and record the numbers in "Spike result". Pick the crate with the higher sequential throughput, provided it negotiates SMB3 encryption and NTLM. Delete the losing feature and the spike test, and make the winner a plain dependency.
- [ ] **Step 4:** Define the public types in `src/lib.rs`:

```rust
pub struct SmbTarget { pub host: String, pub port: u16, pub share: String }
pub struct SmbCredentials { pub user: String, pub password: String, pub domain: Option<String> } // user "" = guest
pub struct SmbEntry { pub path: String, pub name: String, pub is_dir: bool, pub size: u64, pub modified_ms: i64, pub unreadable: bool }
#[derive(thiserror::Error, Debug)]
pub enum SmbError { #[error("unreachable: {0}")] Unreachable(String), #[error("unauthorized")] Unauthorized, #[error("not found")] NotFound, #[error("smb1 only")] Smb1Only, #[error("{0}")] Other(String) }
pub enum Heal { Healthy, ReboundSamePort, ReboundNewPort }
```

  Paths are share-relative, `/`-separated, and start with `/` (the share root is `/`).
- [ ] **Step 5:** Write `connects_to_guest_share`, which opens the guest share's root and expects success. Run `tests/samba/run-samba.sh` then `cargo test --manifest-path player/rust/mydia_smb/Cargo.toml`. Expected: PASS. It also passes as a skip with no env set.
- [ ] **Step 6:** In `ci.yml`, after "Media names tests", add a step "SMB tests": `sudo apt-get install -y samba`, then `eval "$(player/rust/mydia_smb/tests/samba/run-samba.sh)"`, then `devenv shell -- cargo test --manifest-path player/rust/mydia_smb/Cargo.toml`. `check-rust.sh` picks the crate up by glob, so it needs no change.
- [ ] **Step 7:** Commit: `feat(player): add mydia_smb crate with a Samba test harness`.

**Spike result:** _(filled in at Step 3: the numbers for both crates and the choice)_

---

### Task 2: `SmbClient`: list, stat, probe, shares, errors

**Files:**
- Create: `player/rust/mydia_smb/src/client.rs`
- Test: `player/rust/mydia_smb/tests/integration.rs`, plus unit tests in `client.rs` for error mapping

**Interfaces:**
- Consumes: Task 1 types.
- Produces:

```rust
impl SmbClient {
    pub fn new() -> Arc<Self>;
    pub async fn list(&self, t: &SmbTarget, c: &SmbCredentials, dir: &str) -> Result<Vec<SmbEntry>, SmbError>;
    pub async fn stat(&self, t: &SmbTarget, c: &SmbCredentials, path: &str) -> Result<Option<SmbEntry>, SmbError>;
    pub async fn probe(&self, t: &SmbTarget, c: &SmbCredentials, root: &str) -> Result<(), SmbError>;
    pub async fn list_shares(&self, host: &str, port: u16, c: &SmbCredentials) -> Result<Vec<String>, SmbError>;
    pub async fn open(&self, t: &SmbTarget, c: &SmbCredentials, path: &str) -> Result<SmbFile, SmbError>;
}
impl SmbFile { pub fn size(&self) -> u64; pub async fn read_at(&self, offset: u64, len: usize) -> Result<Vec<u8>, SmbError>; }
```

  Pool key: `(host, port, share, user, domain)`. `list` skips `.` and `..`. `list_shares` returns disk shares only, without `IPC$` or any name ending in `$`.

- [ ] **Step 1:** Write the failing tests:
  - `lists_guest_root`: entries include `Fable of Glass (2031)` with `is_dir == true`.
  - `stats_fixture_size`: `stat("/Fable of Glass (2031)/Fable of Glass (2031).mkv")` returns size `67108864`.
  - `stat_missing_is_none`: `stat("/nope.mkv")` returns `Ok(None)`.
  - `lists_and_stats_awkward_names`: `Odd #1 50% ?é.mkv` appears in `list("/")`, and `stat` on its path returns size 1024.
  - `wrong_password_is_unauthorized`: returns `Err(Unauthorized)`.
  - `missing_share_is_not_found`: target share `nope` returns `Err(NotFound)`.
  - `closed_port_is_unreachable`: port 1 returns `Err(Unreachable(_))` within 10 s.
  - `smb1_server_is_smb1_only`: port 4456 returns `Err(Smb1Only)`.
  - `denied_entry_is_unreadable_not_fatal`: listing `/` on `auth` succeeds, and `denied` has `unreadable == true`.
  - `encrypted_share_lists`: listing `/` on `enc` succeeds.
  - `shares_exclude_admin`: `list_shares` contains `guest` and `auth` and nothing ending in `$`.
  - `read_at_matches_pattern`: reading 4096 bytes at offset 1_000_000 matches the formula.
- [ ] **Step 2:** Run the tests against the harness. Expected: FAIL (not implemented).
- [ ] **Step 3:** Implement `client.rs` with `fn map_status(status) -> SmbError` following the spec's table. `STATUS_ACCESS_DENIED` during session setup or tree connect is `Unauthorized`. During a per-entry query inside `list` it sets `unreadable` instead. A connection idle for 60 s is dropped by a sweep task spawned on first use.
- [ ] **Step 4:** Unit test `idle_connections_close_after_60s` uses tokio's paused clock and a pool entry with a fake connection. Run all tests. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(player): SMB client with listing, stat and share enumeration`.

---

### Task 3: `StreamServer`: tokens, ranges, reconnect, heal

**Files:**
- Create: `player/rust/mydia_smb/src/range.rs`, `src/stream.rs`
- Test: unit tests in `range.rs`, integration tests in `tests/integration.rs`

**Interfaces:**
- Consumes: `SmbClient::open`, `SmbFile`.
- Produces:

```rust
pub enum ByteRange { From(u64), FromTo(u64, u64), Suffix(u64) }
pub fn parse_range(header: &str) -> Option<ByteRange>;           // only "bytes=", single range
impl StreamServer {
    pub async fn start(client: Arc<SmbClient>) -> std::io::Result<Arc<Self>>;
    pub fn port(&self) -> u16;
    pub fn open(&self, account: &str, t: SmbTarget, c: SmbCredentials, path: &str) -> String; // full URL
    pub fn close_account(&self, account: &str);
    pub async fn heal(&self) -> std::io::Result<Heal>;
}
```

  `open` only registers the token; the first request opens the SMB file. Responses:
  - `HEAD`/`GET` without `Range`: 200 with `Content-Length`, `Accept-Ranges: bytes`, `Content-Type: application/octet-stream`.
  - With a satisfiable `Range`: 206 with `Content-Range: bytes a-b/size`.
  - Unsatisfiable: 416 with `Content-Range: bytes */size`.
  - Unknown or expired token: 404.
  - An SMB error after one reconnect: 502.

  Bodies stream in 1 MiB `read_at` chunks, with one chunk read ahead.

- [ ] **Step 1:** Write the `range.rs` unit tests:
  - `bytes=0-` gives `From(0)`.
  - `bytes=10-19` gives `FromTo(10,19)`.
  - `bytes=-500` gives `Suffix(500)`.
  - `bytes=0-1,5-9`, `items=0-1` and `bytes=x-` give `None`.
- [ ] **Step 2:** Write the integration tests, using `reqwest` as a dev-dependency client:
  - `head_reports_size`: 200 with `Content-Length: 67108864`.
  - `range_returns_exact_bytes`: `bytes=1000000-1004095` gives 206 and bytes matching the formula.
  - `tail_range_reads_only_the_tail`: `bytes=-4096` gives 206 and `Content-Range: bytes 67104768-67108863/67108864`. A counter on `SmbFile` (behind `cfg(test)` or a `test-introspection` feature) records no read below offset 67104768.
  - `past_end_is_416`.
  - `unknown_token_is_404`.
  - `closed_account_tokens_404`: after `close_account`, the old URL returns 404.
  - `token_expires_after_12h_unused`: tokio paused clock, advance 12 h plus 1 s, expect 404.
  - `abandoned_response_does_not_poison_next_request`: start a full GET, drop it after 1 MiB, then a range request succeeds.
  - `reconnects_once_after_server_restart`: GET a range, restart smbd through the harness (`run-samba.sh restart`), GET another range, expect 206.
  - `heal_without_loss_is_healthy`.
  - `url_carries_no_path`: the URL matches `^http://127\.0\.0\.1:\d+/smb/[0-9a-f]{32}$`.
- [ ] **Step 3:** Run. Expected: FAIL.
- [ ] **Step 4:** Implement with hyper 1.x `server::conn::http1` on a `TcpListener`. Tokens live in `Mutex<HashMap<String, TokenEntry { account, target, creds, path, last_used }>>`. `heal()` checks whether the listener still accepts a loopback connection. If not, it rebinds the old port first, then `:0`, and returns the matching `Heal`.
- [ ] **Step 5:** Run all crate tests. Expected: PASS.
- [ ] **Step 6:** Commit: `feat(player): loopback range server for SMB playback`.

---

### Task 4: FRB surface and Dart `SmbNative`

**Files:**
- Create: `player/rust/mydia_player_p2p/src/smb.rs`
- Modify: `player/rust/mydia_player_p2p/src/lib.rs` (`pub mod smb;`), `player/rust/mydia_player_p2p/Cargo.toml` (`mydia_smb` under `cfg(not(target_arch = "wasm32"))`)
- Generated: `player/lib/native/smb.dart`, `player/lib/native/frb_generated*.dart`, `player/rust/mydia_player_p2p/src/frb_generated.rs`
- Create: `player/lib/core/sources/files/smb_native.dart`, `player/test/core/sources/files/fake_smb_native.dart`
- Modify: `player/lib/core/sources/files/files_account.dart` (add `SmbCredentials`: `user`, `password`, `String? domain`, `toJson()`, `static fromJson(String)` throwing `FormatException`, the same shape as `WebDavCredentials`)
- Test: `player/test/core/sources/files/smb_native_test.dart`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces (Rust FFI, every function `async`, every one `Result<_, FfiSmbError>`):

```rust
pub struct FfiSmbTarget { pub host: String, pub port: u16, pub share: String }
pub struct FfiSmbCredentials { pub user: String, pub password: String, pub domain: Option<String> }
pub struct FfiSmbEntry { pub path: String, pub name: String, pub is_dir: bool, pub size: u64, pub modified_ms: i64, pub unreadable: bool }
pub enum FfiSmbErrorKind { Unreachable, Unauthorized, NotFound, Smb1Only, Unsupported, Other }
pub struct FfiSmbError { pub kind: FfiSmbErrorKind, pub message: String }
pub enum FfiHeal { Healthy, ReboundSamePort, ReboundNewPort }
smb_list(target, creds, dir) -> Vec<FfiSmbEntry>
smb_stat(target, creds, path) -> Option<FfiSmbEntry>
smb_probe(target, creds, root) -> ()
smb_list_shares(host, port: u16, creds) -> Vec<String>
smb_open(account_id: String, target, creds, path) -> String
smb_close_account(account_id: String) -> ()
smb_heal_listener() -> FfiHeal
```

  Native: one `OnceCell<Arc<SmbClient>>` and one `OnceCell<Arc<StreamServer>>`, the server started on the first `smb_open`. Each body runs on the core runtime: `let _guard = runtime::enter(); runtime::spawn(...)`, awaiting the handle, as `lib.rs` already does. `smb_heal_listener` with no server started returns `Healthy`. On wasm, every function returns `FfiSmbError { kind: Unsupported, .. }`.

- Produces (Dart, `smb_native.dart`):

```dart
class SmbTarget { const SmbTarget({required this.host, required this.port, required this.share}); ... }
abstract interface class SmbNative {
  Future<List<FileEntry>> list(SmbTarget t, SmbCredentials c, String dir);
  Future<FileEntry?> stat(SmbTarget t, SmbCredentials c, String path);
  Future<void> probe(SmbTarget t, SmbCredentials c, String root);
  Future<List<String>> listShares(String host, int port, SmbCredentials c);
  Future<String> open(String accountId, SmbTarget t, SmbCredentials c, String path);
  Future<void> closeAccount(String accountId);
  Future<ProxyHeal> healListener();
  Stream<ProxyHeal> get heals; // every non-healthy healListener result
}
const kSmb1OnlyReason = 'smb1-only';
final smbNativeProvider = Provider<SmbNative>((_) => FfiSmbNative());
```

  Error mapping, done once in `FfiSmbNative`:
  - `Unreachable` → `BackendUnreachable(message)`
  - `Unauthorized` → `BackendUnauthorized()`
  - `NotFound` → `BackendNotFound(message)`
  - `Smb1Only` → `BackendUnreachable(kSmb1OnlyReason)`
  - `Unsupported` and `Other` → `BackendUnreachable(message)`

  `FakeSmbNative` keeps an in-memory tree per share, a configurable failure, and records `open` and `closeAccount` calls.

- [ ] **Step 1:** Write `smb_native_test.dart` with a test per mapping row, plus the `SmbCredentials` JSON round trip and `fromJson('{}')` throwing `FormatException`. The test runs a `FfiSmbNative` against an injected `Future<T> Function()` seam: `FfiSmbNative.forTest(invoke)` exercises `_mapError` without the native library.
- [ ] **Step 2:** Run `./dev flutter test test/core/sources/files/smb_native_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Write `src/smb.rs` with the wasm stubs. Run `flutter_rust_bridge_codegen generate` from `player/` (the version must equal the pinned `=2.13.0`), then write `smb_native.dart`.
- [ ] **Step 4:** Run:
  - `cargo build --manifest-path player/rust/mydia_player_p2p/Cargo.toml`
  - the same with `--target wasm32-unknown-unknown`
  - `scripts/check-rust.sh`
  - the Dart test

  Expected: all succeed and PASS.
- [ ] **Step 5:** Commit: `feat(player): expose the SMB client to Dart`.

---

### Task 5: Shared remote folder picker (refactor)

**Files:**
- Create: `player/lib/presentation/widgets/files/remote_folder_picker.dart`
- Modify: `player/lib/presentation/screens/sources/add_webdav_screen.dart` (the folder-browsing part around lines 140-330: `_dir`, up button, `_folderRow`, the no-folders text)
- Test: `player/test/presentation/screens/sources/add_webdav_screen_test.dart` (unchanged, must stay green), `player/test/presentation/widgets/files/remote_folder_picker_test.dart`

**Interfaces:**
- Produces: `RemoteFolderPicker({required FileSystemBackend backend, required String root, required ValueChanged<String> onPicked, Key? key})`. It lists directories only, skips `unreadable` ones, and has an up button that stops at `root`, a "This folder" row, and the empty text. Copy keeps the existing `filesWebDav*` keys. Rename them to `filesPick*` in all four ARB files, since both protocols use them now.

- [ ] **Step 1:** Write `remote_folder_picker_test.dart`: over `FakeBackend` with `/A/B`, tapping `A` shows `B`, up returns to `/`, up is disabled at root, and "This folder" calls `onPicked('/A')`.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Extract the widget and use it from `AddWebDavScreen`.
- [ ] **Step 4:** Run the new test and `add_webdav_screen_test.dart`. Expected: PASS.
- [ ] **Step 5:** Commit: `refactor(player): share the remote folder picker`.

---

### Task 6: SMB accounts, backend and source wiring

**Files:**
- Modify: `player/lib/core/sources/files/files_account.dart`, `files_accounts.dart`, `files_providers.dart` (`defaultFilesBackend`, `buildFilesSource` `onDispose`)
- Create: `player/lib/core/sources/files/backend/smb_backend.dart`
- Modify: `player/lib/core/router/app_router.dart` (`filesReauthLocation`, plus the route `/sources/add/smb` pointing at a placeholder until Task 8)
- Test: `player/test/core/sources/files/files_ids_test.dart`, `files_accounts_test.dart`, `backend/smb_backend_test.dart`, `files_media_source_test.dart`, and the router test holding `filesReauthLocation` cases

**Interfaces:**
- Consumes: `SmbNative`, `SmbTarget`, `kSmb1OnlyReason` (Task 4).
- Produces:

```dart
String normalizeSmbUrl(Uri url);               // see Global Constraints
String smbAccountId(Uri url);
bool isSmbAccountId(String id) => id.startsWith('s');
SmbTarget smbTargetOf(Uri normalized);         // port 445 when absent
// SmbCredentials comes from Task 4.
// FilesAccounts
Future<SourceId> addSmbAccount({required Uri url, required SmbCredentials credentials});
Future<void> addSmbRoot(SourceId id, {required String path, required FilesLibraryKind kind});
// smb_backend.dart
class SmbBackend implements FileSystemBackend { SmbBackend({required SmbNative native, required String accountId, required SmbTarget target, required SmbCredentials credentials}); }
class LazySmbBackend implements FileSystemBackend { LazySmbBackend({required SmbNative native, required String accountId, required SmbTarget target, required Future<String?> Function() credentials}); Future<void> close(); }
```

  - `addSmbAccount` mirrors `addWebDavAccount`: the credentials are written before the record, a known URL reuses its account and clears `needsReauth`, the display name is the host, and the server connection is the normalized URL with `local: isPrivateHost(host)`.
  - `SmbBackend.probe()` probes `/`.
  - `playable(path)` returns `PlayableFile(url: await native.open(...))`.
  - `LazySmbBackend` drops its cached backend on `BackendUnauthorized`, like `LazyWebDavBackend`, and `close()` calls `native.closeAccount`.
  - `defaultFilesBackend` checks `isSmbAccountId` before the WebDAV fallback.
  - `onDispose` closes either lazy backend.
  - `filesReauthLocation` sends an `s…` account to `/sources/add/smb?account=<id>`.

- [ ] **Step 1:** Write the failing tests:
  - `normalizes_equivalent_addresses`: `smb://NAS.local/Media/`, `smb://nas.local:445/media` and `smb://nas.local/MEDIA` give equal ids, and `smb://nas.local:4455/media` gives a different one.
  - IPv6 `smb://[fe80::1]/m` keeps its brackets.
  - `addSmbAccount` twice with the same URL yields one record and the newer credentials.
  - `SmbBackend` over `FakeSmbNative`: list, stat, playable URL passthrough, and `BackendUnauthorized` resets `LazySmbBackend`.
  - The `close()` call reaches `closeAccount`.
  - `filesReauthLocation('s0123456789abcdef')` returns `/sources/add/smb?account=s0123456789abcdef`.
  - A files source built for an SMB account joins the existing `files_media_source_test.dart` contract cases with `FakeSmbNative`.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `./dev flutter test test/core/sources/files test/core/router`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(player): SMB files accounts and backend`.

---

### Task 7: mDNS discovery

**Files:**
- Create: `player/lib/core/sources/files/smb_discovery.dart`
- Modify: `player/ios/Runner/Info.plist`, `player/macos/Runner/Info.plist`
- Test: `player/test/core/sources/files/smb_discovery_test.dart`

**Interfaces:**
- Produces:

```dart
class DiscoveredSmbServer { const DiscoveredSmbServer({required this.name, required this.host, required this.port}); }
abstract interface class SmbDiscovery { Stream<List<DiscoveredSmbServer>> browse(); }
final smbDiscoveryProvider = Provider<SmbDiscovery>((_) => BonsoirSmbDiscovery());
```

  `browse()` starts a bonsoir browse of `_smb._tcp` on listen and stops it on cancel. It emits the current list, de-duplicated by host (first name wins) and sorted by name, after each resolve or loss. Follow `lib/core/cast/bonsoir_chromecast_discovery.dart` for bonsoir's event handling. Browsing errors (permission denied, no multicast) emit an empty list and are logged, never thrown.

  Info.plist:
  - Add `_smb._tcp` to `NSBonjourServices`.
  - Set `NSLocalNetworkUsageDescription` to "Mydia needs local network access to find Chromecast and DLNA devices to cast to, and file shares to play from."

- [ ] **Step 1:** Write tests against a fake event source injected through `BonsoirSmbDiscovery.forTest(Stream<BonsoirDiscoveryEvent>)`:
  - Two resolves for the same host give one entry.
  - A lost service removes it.
  - An error event gives `[]`.
  - Cancelling the subscription stops the browse.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(player): discover SMB servers over mDNS`.

---

### Task 8: SMB add and re-login screen

**Files:**
- Create: `player/lib/presentation/screens/sources/add_smb_screen.dart`
- Modify: `player/lib/presentation/screens/sources/add_source_screen.dart` (entry after WebDAV), `player/lib/core/router/app_router.dart` (real builder for `/sources/add/smb`), the four ARB files
- Test: `player/test/presentation/screens/sources/add_smb_screen_test.dart`, `add_source_entry_test.dart`

**Interfaces:**
- Consumes: `smbDiscoveryProvider`, `smbNativeProvider`, `filesAccountsProvider.addSmbAccount/addSmbRoot`, `RemoteFolderPicker`, `FilesLibraryKindPicker`, `kSmb1OnlyReason`.
- Produces: `AddSmbScreen({String? reauthAccountId})`. Entry `ListTile(key: Key('add-source-smb'), leading: Icon(Icons.lan_rounded), title: ExperimentalTitle(title: Text('SMB')))`, hidden on web, subtitle `sourcesAddSmbSubtitle`.

  The steps, each a keyed widget:
  1. `#smb-servers`: one row per discovered server (`Key('smb-server-<host>')`), then `Key('smb-manual')` "Enter address", with the hint `filesSmbManualHint`.
  2. `#smb-login`: host (prefilled from discovery, editable only for manual entry), optional port, user, password, domain, and `Key('smb-guest')` "Connect as guest". Connect calls `listShares`.
  3. `#smb-shares`: one row per share.
  4. `RemoteFolderPicker` over an unsaved `SmbBackend` whose `accountId` is the would-be `smbAccountId`.
  5. `FilesLibraryKindPicker`, then save with `addSmbAccount` and `addSmbRoot`, and pop.

  In re-login mode (`reauthAccountId` set), it goes straight to the login step for the stored host and share, saves only credentials, and pops.

  Error copy (new ARB keys):
  - `filesSmbUnreachable`: "Can't reach the server."
  - `filesSmbUnauthorized`: "The username or password is wrong."
  - `filesSmbSmb1Only`: "This server only speaks SMB1, which the player doesn't support. Turn on SMB2 or later in its settings."
  - `filesSmbNoShares`: "This server has no shared folders you can open."
  - `filesSmbManualHint`: "Windows PCs usually need to be entered by address."
  - `filesSmbNoneFound`: "No file shares found on this network."
  - `filesSmbLocalNetworkDenied`: "Allow local network access in Settings to find shares, or enter an address."

  Shown when browsing errors or yields nothing for 5 s on iOS: `filesSmbNoneFound`, plus `filesSmbLocalNetworkDenied` on iOS.

- [ ] **Step 1:** Write widget tests with `FakeSmbDiscovery` and `FakeSmbNative`:
  - A discovered server row leads to login with the host prefilled.
  - Manual entry works.
  - Guest connects with an empty user.
  - The share list leads to the folder picker and the kind picker, saving one account with one root.
  - Each error kind shows its copy, `BackendUnreachable(kSmb1OnlyReason)` showing `filesSmbSmb1Only`.
  - Re-login saves new credentials without asking for a share.
  - `add-source-smb` is hidden when `isWeb`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Run `./dev flutter gen-l10n` (or the repo's l10n step from `player/docs/l10n.md`) and the catalog check it names.
- [ ] **Step 4:** Run the screen tests, `add_source_entry_test.dart` and `./dev flutter analyze`. Expected: PASS, no issues.
- [ ] **Step 5:** Commit: `feat(player): add SMB shares from the Add source screen`.

---

### Task 9: Heal the SMB listener on resume

**Files:**
- Modify: `player/lib/app.dart` (the resumed branch around line 495), `player/lib/presentation/screens/player/player_screen.dart` (subscription near line 1223 and its dispose)
- Test: the player screen test file covering `_onProxyHeal` (find it with `grep -rln "ProxyHeal" player/test`)

**Interfaces:**
- Consumes: `SmbNative.healListener()`, `SmbNative.heals`.
- Produces: on resume, `app.dart` calls `ref.read(smbNativeProvider).healListener()` beside the media proxy heal, logging failures the same way. `PlayerScreen` also listens to `smbNative.heals` and routes each event to the existing `_onProxyHeal`, so a `reboundNewPort` reopens the file at its last good position. The reopen re-resolves through `FilesStreamResolver`, which calls `playable()` again and gets a token on the new port.

- [ ] **Step 1:** Write the test: with `FakeSmbNative`, a files playback that has advanced, then `heals.add(ProxyHeal.reboundNewPort)`, gets reopened. `FakeSmbNative.open` is called a second time and the player opens the new URL. `reboundSamePort` does nothing.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Cancel the subscription where `_proxyHealSubscription` is cancelled.
- [ ] **Step 4:** Run the test and `./dev flutter analyze`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(player): recover SMB playback when the app resumes`.

---

### Task 10: Docs, spec sync and manual verification

**Files:**
- Modify: `design/specs/2026-11-07-player-smb-files-design.md` (crate location is `player/rust/mydia_smb`, exposed through `mydia_player_p2p/src/smb.rs`; the account is one share, normalized as in Global Constraints; record the crate chosen in Task 1)
- Modify: `player/lib/core/sources/README.md` (files section: the SMB backend, `s…` account ids, the loopback server, Samba harness usage)
- Modify: `native/README.md` only if it lists player crates

- [ ] **Step 1:** Update the docs above.
- [ ] **Step 2:** Run `./dev flutter test` and `scripts/check-rust.sh`. Expected: PASS.
- [ ] **Step 3:** Manual, recorded in the PR body:
  - Linux desktop against the harness's guest and auth shares: add, scan, play, seek to the end, background, resume.
  - Android TV against a NAS or Samba on the LAN: discovery shows it, then add and play.
  - iOS: the local-network prompt appears, and the server is discovered and plays.
  - A Windows share entered by address.
- [ ] **Step 4:** Commit: `docs(player): document SMB files libraries`.
