# SMB shares reconnect by hostname

## Problem

A share picked from mDNS discovery is saved with one address: the first
IPv4 the server advertised (`add_smb_screen.dart` `_pickServer`, and
`BonsoirSmbDiscovery._connectHosts`, which keeps the hostname only when no
address exists). `LazySmbBackend` connects to `connections.first` and
nothing else. When the NAS takes a new DHCP lease the saved share is dead,
and adding it again creates a second account, because `smbAccountId` hashes
the host: watch state, the index, pins and downloads stay with the old one.

There is also no way to change the address of a saved share.

## Goal

- A saved SMB share keeps working when the server's IP changes, without the
  viewer doing anything, as long as the server is still discoverable or its
  hostname resolves.
- The viewer can change the address of a saved share (to a new IP, a LAN
  name, a Tailscale name) and keep everything attached to it.

Scope is SMB only. WebDAV, Jellyfin and Mydia URL logins are unchanged.

## Design

### 1. Stored addresses and identity

`SourceServer.connections` of an SMB record becomes an ordered list of every
way to reach the share, each an `smb://host[:port]/share` URI:

1. the address that answered during the add,
2. the mDNS hostname, without its trailing dot (`nas.local`),
3. the other advertised addresses.

`DiscoveredSmbServer` gains `hostname` (nullable) so the add screen can save
it even when addresses exist. The add screen passes the full list to
`addSmbAccount` (new `alternatives` parameter); the URL it already passes
stays first.

`SourceServer` gains one optional field, `serviceName`: the mDNS instance
name the share was discovered under. It is written to JSON only when set and
read as null when absent. Records written before this change have one
connection and no service name; they load unchanged and gain addresses the
first time a fallback succeeds.

The account id is fixed when the share is added and never recomputed from an
address. `smbAccountId` remains how a new id is minted; lookups of an
existing share go through the record. Adding a share first looks for a stored
SMB record with the same share (case-insensitive) and either an overlapping
connection host or the same `serviceName`, and re-signs that one in (the
existing `signInAgain` path, credentials replaced, `needsReauth` cleared)
instead of creating a second account.

The list is capped at 6 entries. When trimming, the hostname entry is kept
and the oldest IP literals go first.

### 2. Reconnecting

`defaultFilesBackend` passes `LazySmbBackend` every connection
(`targets: List<SmbTarget>`), the `serviceName`, an `SmbDiscovery`, and an
`onReachedVia(SmbTarget)` callback.

`LazySmbBackend._build` tries the targets in order with
`SmbNative.probe` of the share root. Every failure moves on, a refused login
included: once the NAS has moved, its old IP may belong to another SMB host,
which refuses the login, and stopping there would flag the share
`needsReauth` instead of reconnecting it. When every target fails, the first
failure that was not `BackendUnreachable` is thrown, else the last
unreachable one. The add screen's `_listSharesAt` keeps its stop-on-refusal
rule, since it works from a fresh discovery.

When every stored target fails, `serviceName` is set, and not every target
refused the login (then the password is wrong everywhere), it browses
`_smb._tcp` for at most 5 seconds, takes the service with that name, and
tries the addresses it reports (hostname included) that were not already
tried. Without a service name, or when the browse finds nothing, the
original `BackendUnreachable` is thrown, so the existing offline handling is
unchanged.

When the target that answered is not `connections.first`, `onReachedVia`
rewrites the record through `FilesAccounts` (inside the records write queue):
that target first, any newly discovered addresses appended, the cap applied.
A rewrite that loses a race with removal does nothing.

The connected target is the one every later call and `SmbNative.open` use. A
stream already playing keeps the URL it opened with, as with
`RacingConnection`. Reconnection after a failure needs no new trigger:
resume, a network change and opening the source already probe the backend,
and an unreachable result clears `_backend` so the next call builds again.

### 3. Change address

The account detail page (`account_detail_page.dart`) shows a "Change
address" row for SMB accounts. It opens a sheet with host and port fields
and the servers discovery currently sees, as on the add screen.

Saving lists the shares at the new host with the stored credentials
(`SmbNative.listShares`) and requires this account's share to be among them.
On success `FilesAccounts.setSmbAddress(id, ...)` replaces the connections
(the new address first, plus a picked server's hostname and other addresses)
and sets `serviceName` to the picked server's name, or clears it for a typed
host. The account id, roots, index, watch state and downloads are untouched.
`SmbNative.closeAccount(id)` then drops the open connections and playback
URLs, and the source's backend is rebuilt.

Errors map like the add screen's: unreachable, refused login, SMB1 only, and
a new "share not found on this server".

### Strings

New ARB messages for the row, the sheet, and the share-not-found error, in
every locale file, per `player/docs/l10n.md`.

## Testing

- `LazySmbBackend`: order of attempts; a refused login stops at the first
  target; SMB1 stops; the mDNS fallback with a fake `SmbDiscovery` (found by
  name, not found, no service name); `onReachedVia` called only when a later
  target answered.
- `FilesAccounts`: `addSmbAccount` stores the hostname and alternatives;
  a re-add under a new IP or by hostname reuses the account; the reorder
  rewrite and the cap keep the hostname; a rewrite after removal is a no-op;
  `setSmbAddress` keeps the id and roots.
- `SourceServer` JSON round trip with and without `serviceName`, and an old
  record without it.
- `BonsoirSmbDiscovery._serverFrom` exposes the hostname alongside addresses.
- Widget test for the Change address sheet: success, share not found,
  refused login.

## Not doing

- Parallel racing of SMB addresses. A share has one or two live addresses;
  trying them in order costs one timeout at worst, once, after which the one
  that answered is first.
- Resolving `.local` names ourselves on every connect. They do not resolve
  through Android's `getaddrinfo` or Linux without nss-mdns, which is why the
  service-name browse is the fallback rather than the primary path.
- WebDAV, Jellyfin and Mydia URL logins.
