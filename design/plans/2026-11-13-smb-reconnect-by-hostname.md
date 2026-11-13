# SMB Reconnect by Hostname Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A saved SMB share survives its server changing IP, and the viewer can change a saved share's address without losing anything attached to it.

**Architecture:** An SMB record stores every known address (the one that answered, the mDNS hostname, the other advertised addresses) plus the mDNS service name. `LazySmbBackend` tries them in order, falls back to an mDNS browse by service name, and moves whichever answered to the front of the stored list. The account id is fixed at creation; a "Change address" sheet rewrites the addresses in place.

**Tech Stack:** Flutter, Riverpod, bonsoir (mDNS), the Rust SMB client behind `SmbNative`.

**Spec:** `design/specs/2026-11-13-smb-reconnect-by-hostname-design.md`

## Global Constraints

- SMB only. WebDAV, Jellyfin, Mydia and Plex code paths do not change.
- Records written before this change (one connection, no `serviceName`) must load and work unchanged.
- The account id of an SMB share never changes after it is created.
- At most 6 stored connections per SMB server; trimming keeps the hostname entry and drops the oldest IP literals first.
- mDNS fallback browse: at most 5 seconds.
- Hostnames are stored lowercased with no trailing dot.
- Every user-visible string is an ARB message in all four locale files (`app_en`, `app_es`, `app_pt`, `app_pt_BR`), per `player/docs/l10n.md`.
- Run all commands from `player/`. Tests: `../dev flutter test <path>`. Commit from the worktree with direnv loaded (`direnv exec .. git commit ...`), staging every file first, then `git show --stat HEAD`.

## Decision beyond the spec

The spec says a refused login stops the address loop at once. That breaks the
very case this feature exists for: when the NAS moves, its old IP can be
leased to another SMB host, which refuses the login, and the share would be
flagged `needsReauth` instead of reconnecting. So the loop keeps going on
`BackendUnauthorized` and `BackendNotFound` too, and only after every target
fails does it throw: the first non-unreachable failure if any, else the last
unreachable one. The mDNS fallback runs unless every stored target refused the
login (then the password is wrong everywhere). The add screen's `_listSharesAt`
keeps its own stop-on-refusal rule, since it works from a fresh discovery.

## Review Focus

1. Old IP now belongs to a different SMB host that refuses the login: the share must reconnect via the hostname or mDNS, not flip to `needsReauth`. (Task 4, `stale_ip_refusing_login_falls_through_to_the_hostname`)
2. Two shares on one server saved as two accounts: re-adding share B must not merge into share A's account. (Task 3, `readd_matches_on_share_name_too`)
3. The reorder write racing a removal: a removed share must stay removed. (Task 3, `promote_after_removal_is_a_noop`)
4. IPv6 literal addresses among the stored connections: URIs must keep their brackets and round-trip to the same `SmbTarget`. (Task 2, `ipv6_literal_round_trips`)
5. A pre-change record whose IP moved, with no hostname or service name: it fails exactly as today (unreachable, no browse), and Change address fixes it. (Task 4, `old_record_without_service_name_does_not_browse`; Task 6, `change_address_keeps_id_and_roots`)

---

### Task 1: Model fields

**Files:**
- Modify: `lib/core/sources/source.dart` (`SourceServer`)
- Modify: `lib/core/sources/files/smb_discovery.dart` (`DiscoveredSmbServer`, `_serverFrom`)
- Test: `test/core/sources/source_test.dart` (create if absent; else the existing `SourceServer` JSON test file), `test/core/sources/files/smb_discovery_test.dart`

**Interfaces:**
- Produces: `SourceServer.serviceName` (`String?`), in the constructor, `fromJson`, `toJson` (key `serviceName`, omitted when null), `copyWith({..., String? serviceName, bool clearServiceName = false})`, `==` and `hashCode`.
- Produces: `DiscoveredSmbServer.hostname` (`String?`, lowercased, trailing dot dropped), included in `==`/`hashCode`.

- [ ] **Step 1: Write failing tests**
  - `server_json_round_trips_service_name`: a server with `serviceName: 'NAS'` survives `toJson`/`fromJson`.
  - `server_json_omits_null_service_name`: `toJson()` of a server without one has no `serviceName` key; `fromJson` of a map without the key gives `null`.
  - `copy_with_can_clear_service_name`: `copyWith(clearServiceName: true).serviceName == null`.
  - In `smb_discovery_test.dart`, `resolved_service_exposes_hostname_alongside_addresses`: a resolved service with addresses `['192.168.1.5']` and hostname `'NAS.local.'` yields `host == '192.168.1.5'`, `hostname == 'nas.local'`. Follow the existing test's way of feeding a `BonsoirService`.
- [ ] **Step 2: Run, expect failures** — `../dev flutter test test/core/sources/source_test.dart test/core/sources/files/smb_discovery_test.dart`
- [ ] **Step 3: Implement** the fields. `_serverFrom` sets `hostname` from `service.hostname` regardless of whether addresses exist; `_connectHosts` is unchanged.
- [ ] **Step 4: Run, expect PASS**, plus `../dev flutter analyze lib/core/sources`.
- [ ] **Step 5: Commit** `feat(player): carry the SMB service name and hostname`

### Task 2: Address list helpers

**Files:**
- Create: `lib/core/sources/files/smb_addresses.dart`
- Test: `test/core/sources/files/smb_addresses_test.dart`

**Interfaces:**
- Consumes: `normalizeSmbUrl`, `smbTargetOf`, `kSmbDefaultPort` (`files_account.dart`); `ServerConnection`, `isPrivateHost`.
- Produces:
  - `const kSmbMaxConnections = 6;`
  - `String normalizeSmbHost(String host)` — trim, lowercase, drop trailing dot.
  - `bool isIpLiteral(String host)` — IPv4 dotted quad or contains `:`.
  - `List<ServerConnection> smbConnections({required String share, required int port, required List<String> hosts})` — one `ServerConnection(uri: Uri.parse(normalizeSmbUrl(...)), local: isPrivateHost(host))` per distinct normalized host, in the given order, capped by `capSmbConnections`.
  - `List<ServerConnection> capSmbConnections(List<ServerConnection> all)` — at most `kSmbMaxConnections`; when over, removes IP-literal entries from the end until it fits; never removes a non-literal host.
  - `List<ServerConnection> promoteSmbConnection(List<ServerConnection> current, ServerConnection reached, {List<ServerConnection> discovered = const []})` — `reached` first, then `current` without it, then `discovered` entries not already present, then `capSmbConnections`.
  - `List<SmbTarget> smbTargetsOf(List<ServerConnection> connections)` — `smbTargetOf` of each URI.

- [ ] **Step 1: Write failing tests**
  - `connections_dedupe_and_keep_order`: hosts `['192.168.1.5', 'NAS.local.', '192.168.1.5', '10.0.0.5']` → URIs `smb://192.168.1.5/media`, `smb://nas.local/media`, `smb://10.0.0.5/media`.
  - `non_default_port_is_kept`: port 1445 → `smb://192.168.1.5:1445/media`.
  - `cap_keeps_the_hostname`: 8 entries, hostname at index 7 → 6 entries, hostname present, the trimmed ones are the last IP literals before it.
  - `promote_moves_reached_first_and_appends_discovered`.
  - `ipv6_literal_round_trips`: host `fd00::5` → URI string contains `[fd00::5]`, and `smbTargetsOf` gives `host == 'fd00::5'`, `port == 445`, `share == 'media'`.
- [ ] **Step 2: Run, expect failures.**
- [ ] **Step 3: Implement** the functions above.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(player): helpers for an SMB share's address list`

### Task 3: FilesAccounts stores, matches and rewrites addresses

**Files:**
- Modify: `lib/core/sources/files/files_accounts.dart`
- Test: `test/core/sources/files/files_accounts_test.dart`

**Interfaces:**
- Consumes: Task 1 fields, Task 2 helpers.
- Produces:
  - `addSmbAccount({required Uri url, required SmbCredentials credentials, String? displayName, bool signInAgain = false, List<String> alternatives = const [], String? serviceName})`. `url`'s host is the address that answered; `alternatives` are further hosts (hostname and other addresses) in preference order.
  - `Future<String?> findSmbAccount({required String share, required List<String> hosts, String? serviceName})` — the id of a stored SMB record (`isSmbAccountId`) whose share (from its first connection, case-insensitive) equals `share` and which either has `serviceName` equal and non-null, or shares at least one normalized host.
  - `Future<void> promoteSmbAddress(String accountId, SmbTarget reached, {List<SmbTarget> discovered = const []})` — reads the record fresh; returns if gone; writes `promoteSmbConnection` result with `putAccount(..., replaceOnly: true)`, catching `StateError` (removed meanwhile) as a no-op. Does **not** invalidate `mediaSourceProvider`: the backend that called it is already connected.
  - `Future<void> setSmbAddress(String accountId, {required String host, required int port, List<String> alternatives = const [], String? serviceName})` — replaces connections (share kept from the old first connection), sets `serviceName` (clears it when null), saves with `replaceOnly: true` through `_save` (which invalidates the source), then `smbNativeProvider.closeAccount(accountId)`. Throws `StateError` when the account is gone.

- [ ] **Step 1: Write failing tests** (use the file's existing fixture and `FakeSmbNative`):
  - `add_stores_hostname_and_alternatives`: `alternatives: ['nas.local', '10.0.0.5']`, `serviceName: 'NAS'` → three connections in order, `serviceName == 'NAS'`.
  - `readd_by_new_ip_reuses_the_account`: add via `192.168.1.5` with `serviceName: 'NAS'`, then add via `192.168.1.9` with the same service name → same `SourceId`, one SMB account, connections start with `192.168.1.9`.
  - `readd_by_hostname_reuses_the_account`: second add via `nas.local`, no service name, first record had `nas.local` among its alternatives → same id.
  - `readd_matches_on_share_name_too`: account for share `movies`, then add share `tv` on the same host → two accounts.
  - `promote_moves_reached_first_without_rebuilding`.
  - `promote_after_removal_is_a_noop`: remove the account, then promote → no record, no throw.
  - `set_address_keeps_id_and_roots`: add + `addSmbRoot`, `setSmbAddress(host: '10.0.0.7', port: 445)` → same id, roots unchanged, first connection `smb://10.0.0.7/<share>`, `serviceName == null`, `closedAccounts` contains the id.
- [ ] **Step 2: Run, expect failures.**
- [ ] **Step 3: Implement.** In `addSmbAccount`, resolve the id as `findSmbAccount(...) ?? smbAccountId(url)` before `_stored`. An existing record keeps its name and gets `promoteSmbConnection` of the new hosts, plus `serviceName` when given.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(player): SMB accounts keep every address and a stable id`

### Task 4: LazySmbBackend reconnects

**Files:**
- Modify: `lib/core/sources/files/backend/smb_backend.dart`
- Modify: `lib/core/sources/files/files_providers.dart` (`defaultFilesBackend`)
- Modify: `test/core/sources/files/fake_smb_native.dart`
- Test: `test/core/sources/files/backend/smb_backend_test.dart`

**Interfaces:**
- Consumes: `smbTargetsOf`, `normalizeSmbHost` (Task 2); `FilesAccounts.promoteSmbAddress` (Task 3); `SmbDiscovery`, `DiscoveredSmbServer.addresses`/`hostname`/`port` (Task 1).
- Produces: `LazySmbBackend({required SmbNative native, required String accountId, required List<SmbTarget> targets, required Future<String?> Function() credentials, String? serviceName, SmbDiscovery? discovery, Future<void> Function(SmbTarget reached, List<SmbTarget> discovered)? onReachedVia, Duration browseTimeout = const Duration(seconds: 5)})`.
- `FakeSmbNative` gains `Map<String, BackendFailure> hostFailures` (by `SmbTarget.host`), checked in `probe`/`list`/`stat`/`open` alongside `failure`.

- [ ] **Step 1: Write failing tests**
  - `first_reachable_target_is_used_and_promoted`: targets `[a, b]`, `a` unreachable → calls go to `b`; `onReachedVia(b, [])` called once.
  - `first_target_answering_is_not_promoted`: `onReachedVia` not called.
  - `stale_ip_refusing_login_falls_through_to_the_hostname`: `a` throws `BackendUnauthorized`, `b` (hostname) answers → `b` used.
  - `every_target_refusing_login_rethrows_unauthorized_without_browsing`: `FakeSmbDiscovery.listenCount == 0`.
  - `all_unreachable_browses_by_service_name`: both unreachable, discovery emits a server named `NAS` at `10.0.0.9` → `10.0.0.9` used, `onReachedVia` gets it plus the discovered targets.
  - `browse_ignores_other_names_and_times_out`: emits only `Other`; `browseTimeout: Duration(milliseconds: 50)` → throws the original `BackendUnreachable`; the browse subscription is cancelled.
  - `old_record_without_service_name_does_not_browse`.
  - `unreachable_call_drops_the_built_backend`: build succeeds via `a`, then `a` becomes unreachable on `list` → that `list` throws, the next `list` probes again from the top.
- [ ] **Step 2: Run, expect failures.**
- [ ] **Step 3: Implement.** `_build` probes (`native.probe(t, c, '/')`) each target in order under the failure rule in "Decision beyond the spec"; builds `SmbBackend` on the one that answered. The browse: `discovery.browse()` → `firstWhere` a list containing `name == serviceName`, `.timeout(browseTimeout)`; on timeout or a closed stream, rethrow the original failure. Targets from the discovered server: its `addresses` plus `hostname`, with its port and the share, minus targets already tried. `_call` also drops `_backend` on `BackendUnreachable`. `onReachedVia` is fire-and-forget (`unawaited`, errors logged with `debugPrint`). In `defaultFilesBackend`, pass `targets: smbTargetsOf(source.server.connections)`, `serviceName: source.server.serviceName`, `discovery: ref.read(smbDiscoveryProvider)`, `onReachedVia: (t, d) => ref.read(filesAccountsProvider).promoteSmbAddress(source.account.id, t, discovered: d)`.
- [ ] **Step 4: Run, expect PASS**, then the whole `test/core/sources/files/` directory.
- [ ] **Step 5: Commit** `feat(player): SMB shares fall back to other addresses and mDNS`

### Task 5: Add screen saves every address

**Files:**
- Modify: `lib/presentation/screens/sources/add_smb_screen.dart`
- Test: `test/presentation/screens/sources/add_smb_screen_test.dart`

**Interfaces:**
- Consumes: `addSmbAccount(alternatives:, serviceName:)` (Task 3), `DiscoveredSmbServer.hostname` (Task 1).

- [ ] **Step 1: Write failing test** `picked_server_saves_hostname_and_alternatives`: pick a discovered `NAS` with addresses `['192.168.1.5', '10.0.0.5']`, hostname `nas.local`, finish the flow → the saved record's connections are `192.168.1.5`, `nas.local`, `10.0.0.5` and `serviceName == 'NAS'`. Also `typed_host_saves_no_service_name`.
- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement.** Keep the picked server (`_discovered`, a `DiscoveredSmbServer?`) instead of only its name and addresses. `_save` and `_saveCredentials` pass `alternatives`: the hostname, then the addresses other than `_hostName`; and `serviceName: _discovered?.name`. A typed host passes neither.
- [ ] **Step 4: Run the screen's tests, expect PASS.**
- [ ] **Step 5: Commit** `feat(player): save every discovered address of an SMB share`

### Task 6: Change address

**Files:**
- Create: `lib/presentation/screens/connections/smb_address_sheet.dart`
- Modify: `lib/presentation/screens/connections/account_detail_page.dart` (`AccountControls` Wrap)
- Modify: `lib/l10n/app_en.arb`, `app_es.arb`, `app_pt.arb`, `app_pt_BR.arb`
- Test: `test/presentation/screens/connections/smb_address_sheet_test.dart`, `test/presentation/screens/connections/account_detail_files_test.dart`

**Interfaces:**
- Consumes: `FilesAccounts.setSmbAddress` (Task 3), `SmbNative.listShares`, `smbDiscoveryProvider`, `SmbCredentials.fromJson`, `sourceSecretsProvider.accountToken`.
- Produces: `Future<void> showSmbAddressSheet(BuildContext context, {required SourceAccountRecord record})`.
- ARB keys: `filesChangeAddress` ("Change address"), `filesChangeAddressHost` ("Server address"), `filesChangeAddressSave` ("Save"), `filesChangeAddressShareMissing` ("This server has no share named {share}"), each with an `@` description. Reuse the add screen's existing messages for unreachable, refused login and SMB1.

- [ ] **Step 1: Write failing tests**
  - In `account_detail_files_test.dart`: `smb_account_shows_change_address`: `Key('manage-change-address-<id>')` present for an SMB account, absent for WebDAV and local folders.
  - In `smb_address_sheet_test.dart`:
    - `change_address_keeps_id_and_roots`: enter `10.0.0.7`, save → `setSmbAddress` result visible in the store, same id, sheet closed.
    - `share_missing_shows_error_and_keeps_address`: `FakeSmbNative` has no matching share → `filesChangeAddressShareMissing` text shown, record unchanged.
    - `refused_login_shows_error`: `failure = BackendUnauthorized(...)` → the refused-login message, record unchanged.
    - `picking_discovered_server_fills_host`: `FakeSmbDiscovery` emits `NAS` → tapping it fills the host field and the save passes its hostname, alternatives and service name.
- [ ] **Step 2: Run, expect failures.**
- [ ] **Step 3: Implement** the sheet (host and port `TextField`s, a list of discovered servers, a busy state; keys `smb-address-host`, `smb-address-port`, `smb-address-save`, `smb-address-server-<name>`), the `OutlinedButton` with key `manage-change-address-${account.id}` shown when `isSmbAccountId(account.id)`, and the ARB entries. Run `../dev flutter gen-l10n` (or the project's l10n step from `docs/l10n.md`).
- [ ] **Step 4: Run both test files, expect PASS**; then `../dev flutter analyze`.
- [ ] **Step 5: Commit** `feat(player): change a saved SMB share's address`

### Task 7: Docs and full check

**Files:**
- Modify: `lib/core/sources/README.md` (a short "SMB addresses" paragraph under Connections: stored list, order, mDNS fallback, the stable id, Change address)

- [ ] **Step 1:** Write the paragraph.
- [ ] **Step 2:** `../dev flutter analyze` clean; `../dev flutter test test/core/sources test/presentation/screens/sources test/presentation/screens/connections` passes.
- [ ] **Step 3: Commit** `docs(player): describe how SMB shares are reached`
