# SMB shares in the player's files library

## Why

The files library (`design/specs/2026-11-06-player-files-library-design.md`)
reads local folders and WebDAV shares. Most NAS boxes and every Windows PC
share media over SMB by default, and WebDAV usually has to be switched on or
installed separately. A viewer with an SMB-only share has no way in today.

## Goal

Add SMB as a third files backend, so an SMB share scans, matches and plays
exactly like a WebDAV share, on every native platform, and can be found on the
local network without typing an address where the server advertises itself.

## Decisions

| Question | Decision |
| --- | --- |
| How a share is found | mDNS discovery of `_smb._tcp`, plus manual address entry; after login the server's shares are listed to pick from |
| Protocol versions | SMB 2.x and 3.x only; SMB1-only servers get a clear error |
| Client | Pure-Rust SMB client (`smb2` 0.43.0) in its own crate, `player/rust/mydia_smb`, no libsmbclient |
| How mpv reads a file | A loopback HTTP range server in Rust, addressed by an opaque token |
| Windows PC discovery | Not discovered (they use WS-Discovery, not mDNS); entered by address |
| Web | Not supported, filtered out like WebDAV |

### Rejected

- **A native SMB library per platform** (libsmbclient on Linux and Android,
  AMSMB2 on Apple, UNC paths on Windows): four implementations and a GPL
  dependency for the same result.
- **libmpv built with `smb://`**: a custom media_kit build per platform,
  impossible on iOS, and listing would still need its own client.

## Architecture

Only the backend, the account plumbing, discovery and the add flow are new.
`FileScanner`, `FileMatcher`, `FileLibraryIndex`, the Folders view and the files
playback session are unchanged, because SMB sits behind the existing
`FileSystemBackend` interface.

### Rust: `player/rust/mydia_smb`

The client and the loopback server live in the crate `player/rust/mydia_smb`.
`player/rust/mydia_player_p2p/src/smb.rs` exposes them to Dart. The crate is
native only. On `wasm32` the FRB functions exist and return an "unsupported"
error, because FRB generates bindings for every target.

- **Crate choice.** `smb2` 0.43.0. A spike against a local Samba server
  measured 490-2100 MiB/s sequential (220-590 MiB/s encrypted) and 0.2-1.1 ms
  to first byte, against 22 MiB/s and 42 ms for `smb` 0.12.1.
- **`client.rs`.** A connection pool keyed by `(host, port, share, user)`,
  running on `mydia_p2p_core`'s tokio runtime (this crate never starts its
  own). It provides:
  - `list(dir)`: one directory level as `FileEntry` values;
  - `stat(path)`: one entry, or none when the path is gone;
  - `probe()`: the root folder of the account can be opened;
  - `list_shares(host, port, credentials)`: disk shares only, skipping
    `IPC$` and other administrative `$` shares.

  Connections idle for 60 seconds are closed so a sleeping NAS can spin its
  disks down.
- **Error mapping** onto the existing `BackendFailure` kinds:

  | SMB condition | Failure |
  | --- | --- |
  | Connect timeout, refused, DNS, connection reset | `BackendUnreachable` |
  | `STATUS_LOGON_FAILURE`, `STATUS_ACCESS_DENIED` on session setup or tree connect | `BackendUnauthorized` |
  | `STATUS_ACCESS_DENIED` after connect (`AccessDenied`) | `BackendPermissionLost` |
  | `STATUS_OBJECT_NAME_NOT_FOUND`, `STATUS_OBJECT_PATH_NOT_FOUND`, `STATUS_BAD_NETWORK_NAME` | `BackendNotFound` |
  | Negotiation fails because the server offers only SMB1 | `BackendUnreachable` with the SMB1 message (see Errors) |

  `STATUS_ACCESS_DENIED` on a single entry inside a listing marks that entry
  `unreadable`, the same treatment a WebDAV 403 entry gets, and never fails
  the listing.
- **`stream.rs`.** A loopback HTTP/1.1 server bound to `127.0.0.1:0`. It
  answers `GET` and `HEAD` for `/smb/<token>`, honouring a single
  `Range: bytes=` range with `206 Partial Content`, and `200` with
  `Content-Length` and `Accept-Ranges: bytes` without one. Unknown tokens get
  `404`, and unsatisfiable ranges get `416`. Each response streams pipelined
  SMB `READ`s from the pooled connection.
  - A token is 128 random bits, maps to `(account, path)`, and carries no
    path or credential, so nothing sensitive reaches mpv's logs.
  - Tokens are removed when their account is removed, and after 12 hours
    unused (a response still streaming counts as use). A files source
    rebuilt with new credentials or folders keeps them, since a playback in
    progress streams through them.
  - If the SMB connection drops mid-request, the server reconnects and
    re-opens the file once before failing that request. mpv retries the
    range, so playback resumes after a Wi-Fi blip or a NAS waking.
- **`mydia_player_p2p/src/smb.rs`.** The FRB surface: `smb_list`, `smb_stat`, `smb_probe`,
  `smb_list_shares`, `smb_open` (returns the token URL), `smb_close_account`
  (drops that account's tokens and connections) and `smb_heal_listener`
  (rebinds the loopback listener, returning the same three outcomes as
  `ProxyHeal`).

### Dart: `player/lib/core/sources/files/`

- **`backend/smb_backend.dart`.** `SmbBackend implements FileSystemBackend`,
  a thin layer over the FRB calls that turns their errors into
  `BackendFailure` subclasses. `playable()` calls `smb_open` and returns
  `PlayableFile(url: 'http://127.0.0.1:<port>/smb/<token>')` with no
  headers. `LazySmbBackend` mirrors `LazyWebDavBackend`: it reads the stored
  credentials on first use. Removing the account calls
  `smb_close_account`.
- **`files_account.dart`.**
  - `normalizeSmbUrl(Uri)`: `smb://<host lowercased>[:port when not 445]/<share lowercased>`.
    One account is one share, and roots are share-relative paths.
  - `smbAccountId(Uri)`: `s` plus the first 16 hex characters of SHA-256
    over the normalized URL.
  - `SmbCredentials`: `user`, `password` and an optional `domain`, stored as
    the account token in `SourceSecrets`. An empty `user` means guest.
- **`files_accounts.dart`.** `addSmbAccount` and `addSmbRoot`, shaped like
  their WebDAV counterparts. An account is one share on one server, so the
  same server with two shares is two accounts, matching how one WebDAV base
  URL is one account.
- **`files_providers.dart`.** `defaultFilesBackend` builds a
  `LazySmbBackend` for `s…` accounts.
- **`smb_discovery.dart`.** Browses `_smb._tcp` with `bonsoir` (already a
  dependency) and exposes a stream of `(name, host, port)`, de-duplicated by
  the full set of advertised addresses and the port, so two boxes that share
  only a container bridge address both stay listed. Browsing runs only while the add screen is open. A
  discovered server is connected by its resolved IPv4 addresses, then its
  global IPv6 addresses, then the hostname, because Android and Linux
  without nss-mdns cannot resolve `.local` names. When an address is
  unreachable the next one is tried, and the one that answers is saved.

### Foreground recovery

`app.dart` already calls `MediaProxy.healListener()` on resume. It also calls
`smb_heal_listener()`. When the port changed, tokens already handed to mpv
point at nothing, so an active files playback session re-asks `playable()`
for its file and reopens at the current position, as p2p playback does for
`reboundNewPort`. The heal only reopens SMB playback, never another backend's.

### UI

- "Add source" gains **SMB**, with the existing experimental badge.
- The SMB screen lists servers found on the network, then "Enter address"
  (host or IP, optional port) with the hint "Windows PCs usually need to be
  entered by address".
- After picking a server: a credentials form (user, password, optional domain,
  or "Connect as guest"), then the server's shares, then a folder picker
  inside the chosen share, then the existing library-kind picker.
- After saving a new SMB account, the add flow opens the source's home, like
  the other add screens.
- The new strings are English-only, like the rest of the files library.
- Re-login after `BackendUnauthorized` opens the credentials form for that
  account, the same entry point WebDAV uses. It only replaces the credentials
  of a stored account: a share removed while the sign-in probe ran (or by
  "Forgot PIN") stays removed, and the save reports a failure.

## Errors

- **Discovery finds nothing:** not an error. "Enter address" is always there.
- **SMB1-only server:** "This server only speaks SMB1, which the player
  doesn't support. Turn on SMB2 or later in its settings."
- **Wrong credentials:** `BackendUnauthorized`, so the account shows its
  re-login entry point.
- **Server offline or asleep and not waking:** `BackendUnreachable`, so the
  files library's existing offline behaviour applies.
- **Share requires encryption:** works. The client negotiates SMB3
  encryption.
- **Local-network permission denied on iOS:** discovery shows nothing and the
  screen explains that manual entry still works and the permission can be
  granted in Settings.

## Platforms

| Platform | SMB | Discovery |
| --- | --- | --- |
| Linux, Windows, macOS | yes | mDNS |
| iOS, iPadOS | yes | mDNS; local-network prompt on first browse |
| Android phone, tablet and TV | yes | mDNS; multicast lock held while browsing |
| Web | no | no |

Platform changes:

- iOS and macOS `Info.plist`: add `_smb._tcp` to `NSBonjourServices`, and
  widen `NSLocalNetworkUsageDescription` to cover finding file shares.
- Android already declares `CHANGE_WIFI_MULTICAST_STATE`, and its network
  security config already permits cleartext to loopback.

## Out of scope

- SMB1.
- WS-Discovery or NetBIOS browsing (Windows PCs are entered by address).
- Kerberos and domain-joined single sign-on. NTLM user, password and domain
  only.
- Writing to the share, downloads, and casting from an SMB file.
- NFS, SFTP and cloud drives.

## Testing

- **Spike:** `smb` vs `smb2` throughput and seek latency against Samba, which
  chose `smb2` (see Crate choice).
- **Rust unit:** `Range` parsing (open-ended, suffix, unsatisfiable), token
  issue and expiry, closing an account drops its tokens, and the error mapping
  table.
- **Rust integration:** a Samba container in CI with a guest share and an
  authenticated share, covering list, stat, share enumeration, ranged reads
  through the loopback server, a denied entry inside a listing, wrong
  credentials, and one reconnect after the server drops the connection
  mid-read (`run-samba.sh drop-clients` ends smbd's client processes while
  smbd keeps listening).
- **Dart unit:** `SmbBackend` against a fake FRB API, `normalizeSmbUrl` and
  `smbAccountId`, `SmbCredentials` round trip, and discovery de-duplication.
- **Source contract:** an SMB files source joins the existing files-source
  tests and `SourceKeys` cases.
- **Widget:** the SMB add flow (discovered server, manual entry, guest, share
  list, folder picker) and re-login.
- **Manual:** a Samba or NAS share and a Windows share, played and scrubbed on
  desktop, Android TV and iOS, including resuming after the app was
  backgrounded.
