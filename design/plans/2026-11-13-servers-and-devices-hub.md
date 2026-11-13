# Servers & devices hub Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge the player's "Other servers" and "Paired devices" settings into one promoted **Servers & devices** destination, with a constellation card at the top of Settings and a redesigned hub screen.

**Architecture:** A read-only `connectionsOverviewProvider` folds source records and the peer-sync roster into one immutable model. The Settings card (`ConnectionsConstellationCard`) and the hub (`ConnectionsHub`) render from it. The existing account controls move to `AccountDetailPage` and the pairing UI moves to `PairDeviceSheet`, with their widget keys preserved. Navigation goes through `SettingsNav`, so the phone/TV routes and the desktop dialog both work.

**Tech Stack:** Flutter, Riverpod, go_router, gen_l10n ARB.

**Spec:** `design/specs/2026-11-13-servers-and-devices-hub-design.md`

## Global Constraints

- Every path below is relative to `player/` unless it starts with `design/`.
- No change to `SourceRecords` persistence, the `PeerSyncService` protocol or the relay. The only core change is the read-only getter `PeerSyncService.platform`.
- No Liquid Glass widgets or shader files (otherwise the commit needs `glass-diff`). Use `context.palette` colours and `GlassDialog` only where the spec names it.
- Every user-visible string goes in `lib/l10n/app_en.arb` with an `@key` description (`test/l10n/arb_consistency_test.dart`). Leave `app_es.arb`/`app_pt_BR.arb` alone; Weblate fills them in.
- No real movie or TV titles anywhere. Fixture names: "Home Mydia", "Basement Plex", "NAS", "Living room TV", "Pixel phone".
- Keep the existing keys: `manage-add`, `manage-server-*`, `manage-lock-*`, `manage-all-servers-*`, `manage-reauth-*`, `manage-remove-*`, `manage-switch-user-*`, `manage-settings-*`, `manage-root-*`, `manage-remove-root-*`, `manage-rescan-*`, `pair-*`, `paired-sync-now-button`, `paired-leave-group-button`, `remove-peer-*`.
- **Web (this resolves the spec's open point):** today the paired-devices row shows on web and the servers row does not. Keep that split: on `kIsWeb` the card and the hub show the devices half only.
- Run tests from the repo root with `./dev flutter test --concurrency=1 <path>` (without it, files can be silently dropped; see `player/docs/workflow.md`). Commit with `direnv exec . git commit -m "<msg>"` from the worktree root, then `git show --stat HEAD` to confirm everything staged landed.
- No em dashes in code comments or strings.

## Review Focus

1. **Overflow.** 4+ servers or 3+ devices must collapse into one "+N" node with N = hidden servers + hidden devices, never overlapping nodes. → Task 2, `overflow collapses into a single +N node`.
2. **Hidden sources while locked.** An account whose servers are all `SourceLock.hidden` must not appear in the card, the hub or the counts while `sourceLockProvider` is false. → Task 1, `hidden accounts are excluded while locked`.
3. **Removing the last account from the detail page.** It must pop back to the hub, and the hub must show the empty state. It must not crash on a disposed record. → Task 3, `removing the account pops to the hub`.
4. **A pair that completes while the sheet is open.** The sheet closes, the toast shows once, and the hub's grid gains the device. → Task 4, `sheet closes on onPeerPaired`.
5. **Old deep link `/settings/paired-devices`.** It lands on the hub scrolled to the devices section, not on a 404 or a blank route. → Task 5, `paired-devices route redirects to the hub devices section`.

---

### Task 1: Overview model and provider

**Files:**
- Create: `lib/presentation/screens/connections/connections_overview.dart`
- Modify: `lib/core/p2p/peer_sync_service.dart` (add `String get platform => _platform;` next to `deviceName`)
- Modify: `test/presentation/screens/settings/paired_devices_screen_test.dart` (`FakePeerSyncService` gains `platform`; the file moves in Task 4)
- Test: `test/presentation/screens/connections/connections_overview_test.dart`

**Interfaces:**
- Produces:
  - `enum ConnectionStatus { online, offline, needsSignIn }`
  - `class ConnectionServer { final ProviderAccount account; final SourceKind kind; final String name; final String? host; final int serverCount; final ConnectionStatus status; final bool locked; final bool inAllServers; }`. `host` is the Mydia server URL host when known, else null. `locked` is true when any server's lock is not `SourceLock.none`. `inAllServers` is true when any of its sources is included.
  - `class ConnectionDevice { final String nodeId; final String name; final String platform; final DateTime? lastSyncedAt; }`
  - `class ConnectionsOverview { final String localName; final String localPlatform; final List<ConnectionServer> servers; final List<ConnectionDevice> devices; final bool isPaired; final bool serversFailed; int get onlineCount; }`. `onlineCount` counts `status == online`.
  - `final connectionsOverviewProvider = Provider<ConnectionsOverview>(...)`
  - `IconData connectionPlatformIcon(String platform)`, moved verbatim from `_PairedDevicesBodyState._platformIcon`.
  - All model classes override `==`/`hashCode`.

- [ ] **Step 1: Write the failing tests.** Use a `ProviderContainer` overriding `sourceRecordsProvider`, `sourceLockProvider`, `peerSyncStoreProvider`, `peerGroupRosterProvider` and `peerSyncServiceProvider`:
  - `status derivation`: a server with `presence:false` → offline; all `gone` → offline; `account.needsReauth` → needsSignIn (wins over presence); otherwise online.
  - `hidden accounts are excluded while locked`: with `sourceLockProvider` false, an account whose every server is `SourceLock.hidden` is absent and `servers.length` drops by one. With it true, the account is present with `locked == true`.
  - `devices exclude local and revoked members`: the roster's local node id (with different case) and a `revoked` member are excluded.
  - `lastSyncedAt comes from the peer watermark`: `store.watermark(nodeId).lastSyncedAt == 1700000000000` → `DateTime.fromMillisecondsSinceEpoch(1700000000000)`; no watermark → null.
  - `records error sets serversFailed`: `AsyncError` → `servers` empty, `serversFailed` true.
  - The model does not look at `kIsWeb`; the card and the hub apply the web split.
- [ ] **Step 2: Run** `./dev flutter test --concurrency=1 test/presentation/screens/connections/connections_overview_test.dart`. Expected: FAIL (file missing).
- [ ] **Step 3: Implement.** The provider `ref.watch`es the five providers and rebuilds on `PeerSyncService.onStateChanged`: a `StreamProvider<void>` (`_peerSyncTickProvider`) wrapping `service.onStateChanged`, which the overview watches. The visibility rule is copied from `ManageSourcesBody.build`'s `visible`. `inAllServers` uses `includedInAllServers(source, ref.watch(allServersChoicesProvider))`. `localName`/`localPlatform` come from `service.deviceName`/`service.platform`. `isPaired` is `service.isPaired || devices.isNotEmpty`.
- [ ] **Step 4: Run** the same test. Expected: PASS. Also run `./dev flutter test --concurrency=1 test/presentation/screens/settings/paired_devices_screen_test.dart`. Expected: PASS (the fake compiles).
- [ ] **Step 5: Commit** `feat(player): add the servers and devices overview model`.

### Task 2: Constellation card

**Files:**
- Create: `lib/presentation/screens/connections/constellation_layout.dart` (the pure slot table)
- Create: `lib/presentation/screens/connections/connections_constellation_card.dart`
- Modify: `lib/l10n/app_en.arb`
- Test: `test/presentation/screens/connections/constellation_layout_test.dart`, `test/presentation/screens/connections/connections_constellation_card_test.dart`

**Interfaces:**
- Consumes: `ConnectionsOverview`, `connectionsOverviewProvider`, `connectionPlatformIcon` (Task 1). Navigation goes through `SettingsNavScope.of(context)`; Task 5 adds `openConnections()`. Until Task 5 lands, Task 2 adds that method to `SettingsNav` with the router implementation `_router.push('/sources/manage')` and the dialog implementation `scope.select(SettingsCategory.servers)`.
- Produces:
  - `sealed class ConstellationNode` with `ServerNode(ConnectionServer)`, `DeviceNode(ConnectionDevice)`, `MoreNode(int count)`, `GhostServerNode()`, `GhostDeviceNode()`
  - `class PlacedNode { final ConstellationNode node; final Offset center; }`
  - `List<PlacedNode> layoutConstellation({required List<ConnectionServer> servers, required List<ConnectionDevice> devices, required bool showServers, required Size box})`
  - `class ConnectionsConstellationCard extends ConsumerWidget { const ConnectionsConstellationCard({super.key, this.wide = false}); }`
  - `Key('connections-card')` on the tap target, `Key('connections-card-fallback')` on the error fallback row
  - `SettingsNav.openConnections()`
- Slot table, in fractions of the diagram box. Centre (0.5, 0.46). Server slots: (0.16, 0.21), (0.84, 0.21), (0.11, 0.68). Device slots: (0.89, 0.68), (0.5, 0.80). "+N" takes the last free slot in table order (server slots, then device slots), with N = everything not placed. Ghosts: `GhostServerNode` in server slot 0 when there are no servers and `showServers`, `GhostDeviceNode` in device slot 1 when there are no devices. With fewer than 3 servers, use slots in table order and do not respread (the spec's "spread evenly" is met by the table's spacing; keeping a fixed table means no jitter).
- ARB keys and copy:
  - `connectionsEyebrow` "Your setup"
  - `connectionsTitle` "Servers & devices"
  - `connectionsServersOnline` "{online} of {total} servers online"
  - `connectionsSyncedWith` "{count, plural, one{Synced with 1 device} other{Synced with {count} devices}}"
  - `connectionsNotPaired` "Not paired"
  - `connectionsEmptyFooter` "Add your other servers and sync progress across devices"
  - `connectionsAddServerGhost` "Add a server"
  - `connectionsPairDeviceGhost` "Pair a device"
  - `connectionsMoreNodes` "+{count}"
  - `connectionsThisDevice` "This device"
  - `connectionsCardSemantics` "Servers and devices. {summary}"

- [ ] **Step 1: Write the failing layout tests** (`constellation_layout_test.dart`, pure Dart):
  - `empty shows both ghosts`
  - `two servers one device use slots in order`: centres equal the table entries times `box`
  - `overflow collapses into a single +N node`: 5 servers and 3 devices → exactly 5 nodes: 3 servers, 1 device, and `MoreNode(4)` in the last device slot.
  - `no two nodes share a centre`
  - `showServers false places devices only and no server ghost`
- [ ] **Step 2: Write the failing widget tests** (`connections_constellation_card_test.dart`, overriding `connectionsOverviewProvider` with fixed values):
  - `empty state shows ghost labels`: finds "Add a server" and "Pair a device"
  - `footer counts`: 2 of 3 online, 2 devices → finds "2 of 3 servers online" and "Synced with 2 devices"
  - `semantics label summarises footer`: `tester.getSemantics(find.byKey(Key('connections-card')))` has the label "Servers and devices. 2 of 3 servers online. Synced with 2 devices."
  - `tap opens connections`: a recording `SettingsNav` in `SettingsNavScope` gets `openConnections` once
  - `records error shows fallback row`: `serversFailed` → `Key('connections-card-fallback')` is present and tapping it calls `openConnections`
- [ ] **Step 3: Run** both files. Expected: FAIL.
- [ ] **Step 4: Implement.** Lines are drawn with a `CustomPainter` (`_ConstellationLinesPainter`): solid `palette.surfaceBright` for online servers, dotted for offline, dashed `palette.primary` at 0.55 alpha for devices. Nodes are `Positioned` widgets in a `Stack` sized by `LayoutBuilder`, with a minimum design box of 320×250 and `wide: true` using 640×300. The node and label subtree is wrapped in `ExcludeSemantics`, and the card is a `Semantics(button: true, label: ...)` around an `InkWell` with `Key('connections-card')`. Server monograms: Mydia "M" on a `palette.primary` fill, Plex "P", Jellyfin "J", Stash "S", files: the `Icons.folder_rounded` glyph.
- [ ] **Step 5: Run** both files. Expected: PASS.
- [ ] **Step 6: Commit** `feat(player): add the servers and devices constellation card`.

### Task 3: Account detail page

**Files:**
- Create: `lib/presentation/screens/connections/account_detail_page.dart`. It takes `_AccountCard`'s body, `_AllServersSwitch`, `_FilesRoots`, `unwatchMydiaPeer`, `removeMydiaInstance` and `AddServerButton` from `manage_sources_screen.dart`, moved, not rewritten.
- Modify: `lib/presentation/screens/sources/manage_sources_screen.dart` (delete the moved code; it re-exports nothing; Task 9 deletes the rest)
- Modify: `lib/presentation/screens/settings/settings_nav.dart`, `lib/presentation/screens/settings/dialog/settings_panes.dart`, `lib/core/router/app_router.dart`
- Modify: every importer of `removeMydiaInstance`/`unwatchMydiaPeer` (`grep -rn "removeMydiaInstance\|unwatchMydiaPeer" lib test`)
- Test: move `test/presentation/screens/sources/manage_sources_screen_test.dart` and `manage_files_sources_test.dart` to `test/presentation/screens/connections/account_detail_page_test.dart` and `account_detail_files_test.dart`

**Interfaces:**
- Produces:
  - `class AccountDetailBody extends ConsumerWidget { const AccountDetailBody({super.key, required this.accountId, this.padding = const EdgeInsets.all(16)}); }`
  - `class AccountDetailPage extends ConsumerWidget { const AccountDetailPage({super.key, required this.accountId}); }`: a `Scaffold` whose `AppBar` title is the account's display name
  - `SettingsNav.openAccount(String accountId)` and `SettingsNav.accountRemoved()`. Router: push `/sources/manage/account/$accountId`, and `accountRemoved` pops when the path starts with `/sources/manage/account/`. Dialog: push `AccountDetailBody` in a `SettingsPane` onto the servers pane navigator, and `accountRemoved` calls `_servers.popUntil(isFirst)`.
  - Route `GoRoute(path: '/sources/manage/account/:accountId', name: 'manage_account', parentNavigatorKey: rootNavigatorKey)`, declared before `/sources/manage/:sourceId`
  - `removeMydiaInstance(WidgetRef, ProviderAccount)` and `unwatchMydiaPeer(...)`: same signatures, new file

- [ ] **Step 1: Move the tests.** Change each pump target from `ManageSourcesScreen`/`ManageSourcesBody` to `AccountDetailBody(accountId: ...)`, one account per test, keeping every `find.byKey` as it is. Add:
  - `removing the account pops to the hub`: after confirming remove, a recording `SettingsNav` gets `accountRemoved` once, and pumping further raises no exception when the record is gone
  - `unknown account renders nothing`: `accountId: 'missing'` → `SizedBox.shrink`, no throw
  - `router opens account detail`: `RouterSettingsNav.openAccount('acc1')` → the router location is `/sources/manage/account/acc1`
- [ ] **Step 2: Run** them. Expected: FAIL (types missing).
- [ ] **Step 3: Implement.** `AccountDetailBody` looks the record up by id in `sourceRecordsProvider` and renders the moved card content in a `ListView` (no outer `Card`). It calls `SettingsNavScope.of(context).accountRemoved()` after a successful remove.
- [ ] **Step 4: Run** the moved tests and `test/presentation/screens/settings/settings_nav_test.dart`. Expected: PASS.
- [ ] **Step 5: Commit** `refactor(player): move account controls to an account detail page`.

### Task 4: Pair device sheet

**Files:**
- Create: `lib/presentation/screens/connections/pair_device_sheet.dart`. It takes `_PairingFailure`, `PairingQrCode`, `_scanSupported`, the offer, submit and scan handlers and their UI from `paired_devices_screen.dart`, moved.
- Modify: `lib/l10n/app_en.arb`
- Test: move `test/presentation/screens/settings/paired_devices_screen_test.dart` to `test/presentation/screens/connections/pair_device_sheet_test.dart`; `FakePeerSyncService` moves to `test/presentation/screens/connections/fake_peer_sync_service.dart`

**Interfaces:**
- Produces:
  - `enum PairSheetMode { show, enter }`
  - `class PairDeviceSheet extends ConsumerStatefulWidget { const PairDeviceSheet({super.key, required this.mode}); }`
  - `Future<void> showPairDeviceSheet(BuildContext context, {required PairSheetMode mode})`: `showModalBottomSheet(isScrollControlled: true)` on compact width (< 600), otherwise `showDialog` with a `GlassDialog` around the sheet
  - `PairSheetMode.show` calls `startPairingOffer()` in `initState`. `PairSheetMode.enter` focuses `Key('pair-code-input')`, with the scan button under it when `_scanSupported`.
  - The sheet subscribes to `onPeerPaired`, shows the existing `pairedDevicesConnectedToast` and then pops itself. Popping while an offer is active calls `cancelPairingOffer()`.
- ARB: `connectionsShowCode` "Show pairing code", `connectionsEnterCode` "Enter or scan code"

- [ ] **Step 1: Move the tests.** Pump through `showPairDeviceSheet` from a button, keeping the `pair-*` keys. Drop the tests that only covered the list and leave-group parts (Task 5 owns those). Add:
  - `sheet closes on onPeerPaired`: emit a member on the fake's `onPeerPaired` → the toast text appears once, `find.byType(PairDeviceSheet)` finds nothing
  - `closing with an active offer cancels it`: the fake records `cancelPairingOffer` once
  - `show mode starts an offer on open`
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `refactor(player): move pairing into a pair device sheet`.

### Task 5: Hub screen and routes

**Files:**
- Create: `lib/presentation/screens/connections/connections_hub.dart`, `lib/presentation/screens/connections/connections_hub_cards.dart` (server card, device card, the call-to-action card; keeps the hub file under ~500 LOC)
- Modify: `lib/core/router/app_router.dart`, `lib/presentation/screens/settings/settings_nav.dart`, `lib/l10n/app_en.arb`
- Test: `test/presentation/screens/connections/connections_hub_test.dart`, `test/presentation/screens/settings/settings_nav_test.dart`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `class ConnectionsHubBody extends ConsumerStatefulWidget { const ConnectionsHubBody({super.key, this.padding = const EdgeInsets.all(16), this.initialSection, this.wideHeader = false}); final String? initialSection; }`. `initialSection == 'devices'` scrolls to `Key('connections-devices-section')` after the first frame (`Scrollable.ensureVisible`).
  - `class ConnectionsHubScreen extends StatelessWidget { const ConnectionsHubScreen({super.key, this.initialSection}); }`: `Scaffold` + `AppBar(title: connectionsTitle)`
  - Keys: `connections-this-device`, `connections-servers-section`, `connections-server-<accountId>`, `connections-devices-section`, `connections-device-<nodeId>`, `connections-pair-cta`, `connections-show-code`, `connections-enter-code`, plus the preserved `manage-add`, `paired-sync-now-button`, `paired-leave-group-button`, `remove-peer-<nodeId>` (in the device card's `PopupMenuButton`)
  - Route `/sources/manage` builds `ConnectionsHubScreen(initialSection: state.uri.queryParameters['section'])`. `/settings/paired-devices` becomes `redirect: (_, __) => '/sources/manage?section=devices'`.
  - `RouterSettingsNav.openPairedDevices` pushes `/sources/manage?section=devices`, and `openConnections` pushes `/sources/manage`.
- ARB keys:
  - `connectionsReaching` "Reaching {online} of {total} servers"
  - `connectionsSyncedAgo` "synced {ago}" (use the existing relative-time formatter: `grep -rn "Ago\b\|relativeTime" lib/l10n lib/core/format*`)
  - `connectionsDevicesHint` "Watch progress syncs between these"
  - `connectionsPairCta` "Pair another device"
  - `connectionsPairCtaBody` "Show a code here, or scan one from another screen"
  - `connectionsChipDirect` "Direct connection"
  - `connectionsChipOnline` "Online"
  - `connectionsChipLocked` "Locked"
  - `connectionsChipInAll` "In All servers"
  - `connectionsServerCount` "{count, plural, one{1 server} other{{count} servers}}"
  - `connectionsLeaveGroup` "Leave sync group"
  - The offline and sign-in chips reuse `commonOffline` and `navSourceSignInAgain`. Sync now reuses `pairedDevicesSyncNowButton`.

- [ ] **Step 1: Write the failing tests** (`connections_hub_test.dart`, overriding `connectionsOverviewProvider` and `peerSyncServiceProvider` with the moved fake):
  - `renders sections`: this-device, servers and devices sections are present, with one server card per overview server
  - `mydia tap opens instance, others open account`: recording nav: a Mydia card → `openInstance(mydiaSourceIdOf(record))`; a Plex card → `openAccount('plex-acc')`
  - `chips reflect status`: offline server → "Offline"; needsSignIn → "Sign in again"; locked → "Locked"
  - `pair buttons open the sheet in the right mode`: `connections-enter-code` → `pair-code-input` is focused
  - `sync now and leave group only when paired`
  - `remove device revokes the peer`: open the menu and tap `remove-peer-n1` → the fake records `revokePeer('n1')`
  - `initialSection devices scrolls the devices section into view`: on a 390×600 surface, the devices section's top is within the viewport after `pumpAndSettle`
  - `empty hub shows the add-server ghost and the pair call to action`
- [ ] **Step 2: Add the nav tests** to `settings_nav_test.dart`:
  - `paired-devices route redirects to the hub devices section`: `router.go('/settings/paired-devices')` → `ConnectionsHubScreen` with `initialSection == 'devices'`
  - `openPairedDevices pushes the hub with section=devices`
- [ ] **Step 3: Run** both. Expected: FAIL.
- [ ] **Step 4: Implement.** Server card host line: `server.host` when present, else `connectionsServerCount`. "Direct connection" replaces "Online" for the Mydia account that is currently reached over p2p with a direct path (`sourceViaP2pProvider(id)` plus `p2pStatusNotifierProvider.peerConnectionType`, the same inputs `SettingsScreen` passes to `ConnectionSummary`). The servers section is hidden on `kIsWeb`.
- [ ] **Step 5: Run** both. Expected: PASS.
- [ ] **Step 6: Commit** `feat(player): add the servers and devices hub`.

### Task 6: Settings screen wiring (phone and TV)

**Files:**
- Modify: `lib/presentation/screens/settings/settings_screen.dart` (card after `updateCard`, as `section(0, …)`; delete the `pairedDevicesRow` call in `_ManageSection` and `section(4, SourcesSettingsSection())`)
- Modify: `lib/presentation/screens/settings/widgets/settings_sections.dart` (delete `pairedDevicesRow` and its call in `PlaybackSettingsSection`)
- Test: `test/presentation/screens/settings/settings_screen_test.dart`, `settings_focus_tv_test.dart`

**Interfaces:**
- Consumes: `ConnectionsConstellationCard` (Task 2).

- [ ] **Step 1: Update the tests.**
  - In `settings_screen_test.dart`, replace the `manage-sources-row`/`paired-devices-row` expectations with `connections card sits above playback`: the card's top `dy` is less than that of `default-quality-row`
  - In `settings_focus_tv_test.dart`, add `card is the first focus target after the update card`
  - Assert `paired-devices-row` and `manage-sources-row` are absent
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both files plus `settings_initial_focus_test.dart` and `settings_bodies_nav_test.dart`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): promote servers and devices to the top of settings`.

### Task 7: Desktop settings dialog

**Files:**
- Modify: `lib/presentation/screens/settings/dialog/settings_dialog.dart` (`servers` → `connections`, first in the enum, icon `Icons.hub_outlined`, label `l10n.connectionsTitle`)
- Modify: `dialog/settings_panes.dart` (the connections root page is `ConnectionsHubBody(padding: _bodyPadding, wideHeader: true)` with no `SettingsPane` title duplication; delete `_PairedDevicesPage`; `DialogSettingsNav.openPairedDevices` → `scope.select(connections)` and then the pane scrolls to devices, `openConnections` → `scope.select(connections)`)
- Modify: `dialog/open_settings.dart`:
  - `_categoryFor`: `'/settings'`, `'/sources/manage'` and `'/settings/paired-devices'` → `connections`, so Ctrl+, and the Settings nav entry open the dialog on it
  - `openSettings`'s default `initial` stays `playback`, so with the dialog disabled a bare call still goes to `/settings`
  - the non-dialog `connections` case pushes `/sources/manage`
- Modify: `lib/presentation/screens/all_servers/all_servers_banner.dart` (rename only)
- Test: `test/presentation/screens/settings/dialog/settings_dialog_test.dart`, `open_settings_test.dart`

**Interfaces:**
- Produces: `SettingsCategory.connections`, which replaces `SettingsCategory.servers` everywhere (`grep -rn "SettingsCategory.servers" lib test`).
- The dialog scrolls to devices by keeping a `ValueNotifier<String?> connectionsSection` on `SettingsDialogScope`. `openPairedDevices` sets it to `'devices'`, and the root page passes it as `initialSection`, then clears it.
- `wideHeader: true` swaps the this-device card for `ConnectionsConstellationCard(wide: true)` with taps disabled (`onTap` null, since it is already on the hub).

- [ ] **Step 1: Update and add the tests:**
  - `connections is the first sidebar category`
  - `ctrl-comma opens on connections`
  - `openPairedDevices selects connections and scrolls to devices`
  - `/settings/paired-devices maps to connections`
  - `paired devices is no longer pushed onto playback`
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the `test/presentation/screens/settings/` directory. Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): lead the settings dialog with servers and devices`.

### Task 8: Remove dead code and strings

**Files:**
- Delete: `lib/presentation/screens/sources/manage_sources_screen.dart` and `lib/presentation/screens/settings/paired_devices_screen.dart`, whatever is left of them
- Modify: `lib/l10n/app_en.arb`, `app_es.arb`, `app_pt_BR.arb` (remove the keys nothing references any more, in the same order across files)

- [ ] **Step 1:** For each candidate key (`sourcesOtherServers`, `sourcesSettingsRowTitle`, `sourcesSettingsRowSubtitle`, `settingsPairedDevicesTitle`, `settingsPairedDevicesNotPaired`, `settingsPairedDevicesCount`, `pairedDevicesIntroTitle`, `pairedDevicesIntroBody`, `pairedDevicesListSection`, `pairedDevicesStatusActive`, `pairedDevicesStatusRevoked`, `settingsServers`), run `grep -rn "<key>" lib` and remove it from all three ARBs only when nothing references it.
- [ ] **Step 2: Run** `./dev flutter analyze`. Expected: no issues.
- [ ] **Step 3: Run** `./dev flutter test --concurrency=1 test/l10n test/presentation/screens/connections test/presentation/screens/settings test/presentation/screens/sources`. Expected: PASS.
- [ ] **Step 4: Run** the full suite `./dev flutter test --concurrency=1`. Expected: PASS, apart from the flakes listed in `.github/ci-flakes.md`.
- [ ] **Step 5: Commit** `chore(player): drop the old servers and paired devices screens`.
