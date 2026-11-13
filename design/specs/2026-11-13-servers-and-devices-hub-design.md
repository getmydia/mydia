# Servers & devices hub (player)

## Why

The player connects to more than one Mydia: Plex, Jellyfin, Stash and local
folders, and it syncs watch progress with other paired players. Both features
are hard to find. "Other servers" is the last section of Settings, a single
row reading "Plex, Jellyfin and Stash / Add or remove servers". "Paired
devices" is a row inside Manage on phone and TV and inside Playback in the
desktop dialog. Both screens are stacks of stock Material widgets.

This change merges them into one destination, **Servers & devices**, puts a
visual entry for it at the top of Settings, and restyles both. It changes
presentation and navigation only: the source store, the pairing protocol and
peer sync stay as they are.

Mockups: the "Servers & devices hub" canvas (option A, constellation card,
and the hub screen were approved).

## Goals

- First thing in Settings on phone, TV and desktop.
- One screen for everything this player connects to.
- An empty install invites the user to add a server and pair a device.
- Every existing capability of the two screens survives, reached from the hub.

## Non-goals

- No change to `SourceRecords`, `PeerSyncService`, the relay, or the pairing
  wire format.
- No live reachability probing. Status comes from fields that already exist.
- No library counts (there is no cheap source for them).
- Remote-control rows and Diagnostics stay where they are.
- No Liquid Glass changes: the new widgets use the palette and existing
  surfaces, not the glass widgets.

## Overview model

`presentation/screens/connections/connections_overview.dart` defines
`connectionsOverviewProvider`, a read-only provider that combines:

- `sourceRecordsProvider` and `sourceLockProvider`: one `ConnectionServer`
  per visible account (the same visibility rule `ManageSourcesBody` applies
  today), carrying the account, its kind, its display name, its server count,
  and a status:
  - `online`: some server has `presence` and is not `gone`
  - `offline`: no server has `presence`, or all of them are `gone`
  - `needsSignIn`: `account.needsReauth`
  - `locked`: shown as a chip, not as a status
- `peerSyncStoreProvider`, `peerGroupRosterProvider` and
  `peerSyncServiceProvider`: one `ConnectionDevice` per non-revoked member
  that is not the local node, carrying the device name, the platform and the
  last sync time from that peer's `PeerWatermark.lastSyncedAt`; plus
  `isPaired`
- the local device's name and platform for the centre node

The provider rebuilds on `PeerSyncService.onStateChanged`, as
`pairedDevicesRow` does today. The model types are plain immutable classes
with `==`, so the card does not repaint on unrelated changes.

## Settings card: `ConnectionsConstellationCard`

It replaces `SourcesSettingsSection` and `pairedDevicesRow` in
`SettingsScreen`, placed directly under `SettingsIdentity` and the update card
and above Playback.

- Header: an eyebrow reading "Your setup", the title "Servers & devices", and
  a chevron. The whole card is one tap target that opens the hub.
- Diagram: this device in the centre, ringed in the primary colour. Servers
  are rounded-square nodes with a kind monogram and a status dot, joined by
  solid lines (dotted when offline). Devices are circular platform-icon nodes
  joined by dashed primary-colour lines. Labels sit under each node.
- Up to 3 servers and 2 devices get fixed slots. Anything more collapses
  into one "+N" node. With fewer, the occupied slots are spread evenly. The
  slot positions are a fixed table, so the layout never jitters.
- **Empty state:** with no servers and no paired devices, two dashed ghost
  nodes appear, "Add a server" and "Pair a device", and the footer reads "Add
  your other servers and sync progress across devices".
- Footer: "X of Y servers online" with a status dot, and "Synced with N
  devices", or "Not paired" when there are none.
- The diagram is drawn with a `CustomPainter` for the lines and positioned
  widgets for the nodes. It scales to the card width, with a minimum 320
  logical px design box.
- TV: one focusable item, with the focus ring on the card. It joins the
  `SettingsFocusOrder`/`FocusMemoryRegion` scheme as section 0.
- Accessibility: the card is one `Semantics` button whose label summarises
  the footer ("Servers and devices. 2 of 3 servers online. Synced with 2
  devices."). The nodes are excluded from semantics.
- Errors: if the source records fail to load, the card falls back to a plain
  `SettingsRow.navigation` reading "Servers & devices" that opens the hub. A
  peer-sync failure only blanks the devices half and shows "Not paired".
- Web: the card is hidden, matching today's `kIsWeb` guard on
  `SourcesSettingsSection`. The plan's first task confirms whether pairing
  works on web. If it does, the web build shows the devices half only.

## Hub: `ConnectionsHub`

It is one body widget, used by a phone/TV route with a `Scaffold` and by the
desktop dialog pane, following the `*Body` pattern already used by
`ManageSourcesBody` and `PairedDevicesBody`.

1. **This device card:** the platform icon in the primary ring, the eyebrow
   "This device", the device name, and "Reaching X of Y servers · synced N
   ago". In the desktop dialog this card is replaced by a wide version of the
   constellation, the same widget at a larger design box.
2. **Servers:** a section header with an "Add server" button
   (`Key('manage-add')`, `SettingsNav.addServer`). Then one card per account:
   - the monogram tile (primary fill for Mydia, neutral for others), the
     name, and the kind plus host (or "N servers")
   - chips: status (online/offline/"Sign in again"), "Locked" when any
     server is locked or hidden, and "In All servers" when included
   - a tap on a Mydia card calls `SettingsNav.openInstance` (unchanged). Any
     other kind opens `AccountDetailPage`.
3. **Paired devices:** a section header with the hint "Watch progress syncs
   between these". Then a two-column grid of device cards: the platform
   icon, the name, and the platform plus the last sync time. Long-press or a
   trailing menu offers "Remove device", which calls `revokePeer`, the
   current action.
4. The "Pair another device" call to action, with two buttons: "Show pairing
   code" and "Enter or scan code". Both open `PairDeviceSheet`.
5. Footer links: "Sync now" (`syncAll(ignoreCooldown: true)`) and "Leave sync
   group" (the existing confirmation dialog). They are shown only when
   paired.

The empty states are the same ghost tiles as the card: "Add a server" as a
dashed server card, and the pair call to action alone when there are no
devices.

### `AccountDetailPage`

A page per non-Mydia account that holds, unchanged, what `_AccountCard`
renders today: the per-server rows with the lock button and the "Include in
All servers" switch, `_FilesRoots` for files accounts, "Switch user" for Plex
Home, the reauth button with its kind-specific label, and Remove (after which
it pops back to the hub). These widgets move from `manage_sources_screen.dart`
into `connections/account_detail_page.dart`. The keys stay the same
(`manage-server-*`, `manage-lock-*`, `manage-all-servers-*`,
`manage-reauth-*`, `manage-remove-*`, `manage-root-*`, `manage-rescan-*`) so
existing tests port. `unwatchMydiaPeer`/`removeMydiaInstance` stay public and
move to the same module.

### `PairDeviceSheet`

The offer, QR code, code entry, scanner and failure banner from
`_PairedDevicesBodyState` move here, with the same handlers, the same
`_PairingFailure` value and the same `pair-*` keys. It is a modal bottom sheet
on phone and a `GlassDialog` in the desktop dialog and on TV. It opens on the
"show code" or "enter code" half according to the button pressed. It closes
itself on `onPeerPaired`, after the existing toast.

## Navigation

- `SettingsCategory`: `servers` is renamed `connections` and moved to the
  first position, with the label "Servers & devices" and an icon from the
  `hub`/`devices` family. `openSettings` defaults to it. The
  `'/sources/manage'` mapping in `open_settings.dart` points to it, and
  `'/settings/paired-devices'` maps to it too.
- `DialogSettingsNav.openPairedDevices` selects `connections` and scrolls
  the hub to the devices section. `_PairedDevicesPage` is removed and the
  playback navigator no longer pushes anything.
- `RouterSettingsNav.openPairedDevices` pushes `/sources/manage?section=devices`.
  The hub reads the query parameter and scrolls to that section.
- New `SettingsNav.openAccount(String accountId)` pushes `AccountDetailPage`:
  onto the connections pane navigator in the dialog, and onto
  `/sources/manage/account/:accountId` on the router.
- Router: `/sources/manage` builds the hub. `/settings/paired-devices`
  becomes a redirect to `/sources/manage?section=devices`, so old deep links
  survive. `/sources/manage/:sourceId` (Mydia instance) is unchanged.
- `all_servers_banner.dart` and the compatibility banner keep working
  through the renamed category.
- Deleted: `ManageSourcesScreen`, `ManageSourcesBody`,
  `SourcesSettingsSection`, `PairedDevicesScreen`, `PairedDevicesBody`,
  `pairedDevicesRow`, and the `_ManageSection` and `PlaybackSettingsSection`
  call sites of the paired-devices row.

## Text

New ARB keys follow `player/docs/l10n.md`, including the description
comments: `connectionsTitle`, `connectionsEyebrow`, `connectionsThisDevice`,
`connectionsServersOnline`, `connectionsSyncedWith`, `connectionsNotPaired`,
`connectionsEmptyFooter`, `connectionsAddServerGhost`,
`connectionsPairDeviceGhost`, `connectionsMoreNodes`, `connectionsReaching`,
`connectionsDevicesHint`, `connectionsPairCta`, `connectionsPairCtaBody`,
`connectionsShowCode`, `connectionsEnterCode`, `connectionsChipDirect`,
`connectionsChipOnline`, `connectionsChipLocked`, `connectionsChipInAll`,
`connectionsServerCount`, and `connectionsCardSemantics`. Keys that only the
deleted widgets used are removed. Existing `pairedDevices*` and `sources*`
keys that the moved widgets still use are kept.

## Testing

- `connections_overview_test.dart`: status derivation (online, offline, gone,
  needsReauth, locked or hidden visibility), the exclusion of the local and
  revoked members, and the last-sync mapping.
- `connections_constellation_card_test.dart`: the empty state (ghost nodes),
  the mixed state, overflow ("+N"), the footer text, the semantics label,
  tap → `SettingsNav` hub, and the fallback row on a records error.
- `connections_hub_test.dart`: sections render; a Mydia tap →
  `openInstance`, other kinds → `openAccount`; the `section=devices` scroll;
  Sync now and Leave group appear only when paired.
- `account_detail_page_test.dart`: the moved manage-sources tests, keyed as
  before.
- `pair_device_sheet_test.dart`: `paired_devices_screen_test.dart` moved,
  plus the sheet closing itself on a paired event.
- Nav tests for `RouterSettingsNav` and `DialogSettingsNav`, covering the
  category order and default, the `openPairedDevices` redirect, and the
  `/settings/paired-devices` redirect.
- The TV focus test for Settings covers the card as the first focus target.
