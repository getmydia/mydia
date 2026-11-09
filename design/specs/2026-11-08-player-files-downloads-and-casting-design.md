# Offline downloads and casting for files libraries

## Why

The files library (`design/specs/2026-11-06-player-files-library-design.md` and
`design/specs/2026-11-07-player-smb-files-design.md`) turns local folders,
WebDAV shares and SMB shares into a matched library, but leaves out two things
every server source in the player already offers and Infuse viewers expect:

1. **Offline downloads from network shares.** A viewer with media on a home NAS
   (SMB or WebDAV) cannot save movies or episodes onto their phone, tablet or
   laptop before travelling.
2. **Casting to Chromecast and DLNA.** A viewer browsing a local folder, WebDAV
   share or SMB share has no cast button, because a TV on the LAN cannot read a
   local file path, cannot send a WebDAV `Authorization` header, and cannot
   speak SMB or reach `mydia_smb`'s loopback range listener.

## Goal

Add offline downloads (for WebDAV and SMB shares) and Chromecast/DLNA casting
(for all native `files` sources) without a server-side transcoder, reusing the
existing download pipeline (`DownloadService`) and third-party cast seam
(`SessionSourceCastBinding`).

## Decisions

| Question | Decision |
| --- | --- |
| Which `files` accounts offer downloads | Network shares only (WebDAV `w…` and SMB `s…`); `flocal` files are already on the device |
| What a download fetches | The original video file (`Original` option) and TMDB artwork, matching Plex, Jellyfin and Stash |
| How casting reaches the receiver | A LAN HTTP bridge (`FilesCastBridge`) in Dart on the sender device, bound only while a `files` cast is active |
| Cast stream format | Progressive byte-range streaming (`CastMediaKind.progressive`, `DirectPlayPlan`) for both Chromecast and DLNA; no transcoding |
| Subtitles when casting | `.srt` (converted to WebVTT in Dart) and `.vtt` sidecar files served by `FilesCastBridge` on Chromecast; none on DLNA |
| Watch state and progress | Stored locally in `PlaybackProgressStore` for both offline playback and casting |

## Architecture

### 1. Offline downloads (`player/lib/core/sources/files/`)

- **Capability gate.** `FilesMediaSource` implements `Downloadable`. Its
  `capabilities` include `SourceCapability.downloadable` only when
  `source.account.id != kFilesLocalAccountId` (WebDAV and SMB accounts).
  `FilesMediaSource.as<T>()` returns `null` when `T` is `Downloadable` and
  `!capabilities.contains(SourceCapability.downloadable)`, so callers that check
  `source.as<Downloadable>()` (`downloadManagerProvider`, `startItemDownload`)
  agree with `capabilities`.
- **Exact file size in `original_download.dart`.** `originalOption(version)`
  sets `actualSize: version.sizeBytes` and prefers `version.sizeBytes` over
  `estimatedBytes(version)` for `estimatedSize`; `originalFile` prefers
  `version.sizeBytes` for `expectedBytes`. `FilesCatalog.versionsOf` already
  populates `MediaVersion.sizeBytes` from `IndexedFile.size`.
- **Plan resolution.**
  - `FilesMediaSource.downloadOptions(ref)` calls `originalOptions(this, ref)`.
  - `FilesMediaSource.resolve(ref, optionId)` looks up
    `downloadVersion(await item(ref))` and resolves its backend path with
    `filesBackendPath(root, file.path)`. A missing file or root in the index
    throws `SourceException.unsupportedFault(SourceFault.noFileToDownload)`.
  - It checks `await backend.stat(path)` (`null` throws
    `SourceException.notFound()`) and calls `await backend.playable(path)` to
    get `PlayableFile(url, headers)`:
    - For WebDAV, `playable` returns the share's HTTP(S) URL with the `Basic`
      `Authorization` header.
    - For SMB, `playable` calls `smb_open` and returns
      `http://127.0.0.1:<port>/smb/<token>` with no headers. Because
      `DownloadService` re-runs its plan resolver on every start, resume,
      recovery and restart, an interrupted SMB download gets a fresh loopback
      token and port automatically.
  - Any `BackendFailure` is passed to `reportReachability(failure)` and mapped
    to `SourceException`:

    | `BackendFailure` | `SourceException` | `DownloadService` behaviour |
    | --- | --- | --- |
    | `BackendUnauthorized`, `BackendPermissionLost` | `SourceException.unauthorized()` (and flags `needsReauth`) | Re-resolves once, then fails with sign-in message |
    | `BackendNotFound` | `SourceException.notFound()` | Fails task permanently |
    | `BackendUnreachable` | `SourceException.unreachable()` | Parks task as `interrupted` for recovery sweep |

- **UI surfaces.**
  - Movies, shows (season download) and episodes on WebDAV and SMB shares get
    download controls automatically through `sourceFeatures(source)` in
    `source_detail_mapping.dart`.
  - `SourceItemScreen` (`presentation/screens/sources/source_item_screen.dart`)
    adds a Download button for `ItemKind.video` items when the source lists
    `SourceCapability.downloadable`, so unmatched files in `Folders` (and Stash
    scenes) can be downloaded from their item screen.
- **Account removal.** `SourceRecordsNotifier.removeAccount` and
  `removeLockedAccounts` already call `_deleteDownloads` for the removed
  account prefix, and `orphanDownloadSweepProvider` sweeps any leftovers.

### 2. Casting (`player/lib/core/sources/files/cast/`)

- **Capabilities.** `FilesMediaSource` adds `SourceCapability.castable` to
  `capabilities` for all `files` accounts (`flocal`, WebDAV and SMB).
  `FilesPlaybackSession.features` returns `const {PlaybackFeature.cast}`.
- **`FilesCastBridge` (`files_cast_bridge.dart`).** A Riverpod-managed service
  (`filesCastBridgeProvider`) that exposes a LAN HTTP server only while at least
  one `files` cast session is active:
  - **Binding and LAN address.** On the first `openSession`, it resolves the
    device's LAN IPv4 address using the same interface rules as
    `LocalProxyService.resolveLanAddress()` (shared helper in
    `core/network/lan_address.dart`) and binds an `HttpServer` to
    `InternetAddress.anyIPv4` on port `0`. If no LAN address is available,
    `openSession` throws `SourceException.unreachable()`.
  - **Tokens.** `openSession` generates a 128-bit random hex `token` and stores
    a session entry holding:
    - `Future<PlayableFile> Function() playable` (called per request so a
      rebound SMB port or updated credential takes effect without changing the
      receiver's URL),
    - `String mimeType`,
    - `Map<String, Future<String?> Function()> subtitles` (by `trackId`).
    It returns a `FilesCastTicket` with `sessionId: token`,
    `mediaUrl: 'http://$lanIp:$port/cast/$token/stream.$ext'`, and
    `subtitleUrl(trackId): 'http://$lanIp:$port/cast/$token/sub/$trackId.vtt'`.
  - **Media streaming (`GET` and `HEAD` `/cast/<token>/stream.<ext>`):**
    - Unknown token answers `404`.
    - Sets `Accept-Ranges: bytes`, `Content-Type: <mimeType>`, and
      `Access-Control-Allow-Origin: *`.
    - **Local file** (`playable.url` is not `http://` or `https://`): stats
      `File(playable.url)` (`404` if missing). Without a `Range` header,
      answers `200 OK` with `Content-Length: total` and streams `file.openRead()`
      on `GET`. With `Range: bytes=<start>-[<end>]`, answers `416` with
      `Content-Range: bytes */total` when unsatisfiable, else `206 Partial
      Content` with `Content-Range: bytes start-end/total`,
      `Content-Length: end - start + 1`, and streams
      `file.openRead(start, end + 1)`.
    - **HTTP upstream** (WebDAV URL with `Authorization` header, or SMB loopback
      `http://127.0.0.1:<port>/smb/<smbToken>`): forwards a streamed `GET` or
      `HEAD` request to `playable.url` with `playable.headers` plus the
      receiver's `Range` header, copies the status code (`200`, `206`, `416`,
      or `502` on upstream failure) and `Content-Length` / `Content-Range`
      headers, and pipes the response stream to the receiver socket.
  - **Subtitles (`GET` `/cast/<token>/sub/<trackId>.vtt`):**
    - Calls the registered subtitle loader for `trackId` (`404` if unknown or
      null).
    - Converts `.srt` content to WebVTT in pure Dart (`srtToVtt` in
      `subtitle_vtt.dart`: strips UTF-8 BOM, normalizes `\r\n` to `\n`,
      rewrites `HH:MM:SS,mmm` to `HH:MM:SS.mmm` on `-->` timing lines, and
      prepends `WEBVTT\n\n`; passes content already starting with `WEBVTT`
      through unchanged).
    - Answers `200 OK` with `Content-Type: text/vtt; charset=utf-8` and
      `Access-Control-Allow-Origin: *`.
  - **Teardown and heal.** `closeSession(token)` removes the token, cancels any
    in-flight upstream subscriptions for it, and closes the `HttpServer`
    (`force: true`) when the last token is removed. `healListener()` checks
    whether the bound port still accepts a loopback connection on app resume
    (wired in `app.dart` alongside `MediaProxy.healListener()` and
    `smb_heal_listener()`) and rebinds on the same port when the OS reclaimed
    the socket while suspended.
- **Progressive cast route (`FilesPlaybackSession` and `SessionSourceCastBinding`).**
  - `SourcePlaybackSession` gains `bool get castsAsProgressive => false`,
    overridden to `true` on `FilesPlaybackSession`.
  - In `SessionSourceCastBinding.resolve`:
    - When `_session.castsAsProgressive` is `true`, both Chromecast and DLNA use
      `const DirectPlayPlan(reason: PlanReason.directPlayAccepted)` and build a
      `CastRoute` with `kind: CastRouteKind.localBridge`,
      `mediaKind: CastMediaKind.progressive`, and `transcoded: false`.
    - In `CastSessionManager._retryRouteFor`, a `SourceCastContent` route with
      `attempted.kind == CastRouteKind.localBridge` returns `null` rather than
      retrying with `forceTranscode: true`, since no server exists to transcode
      it.
  - `FilesPlaybackSession.createReceiverResolver` returns a
    `FilesCastStreamResolver` backed by `FilesCastBridge`:
    - `resolve` verifies the file exists on the backend (`stat`), calls
      `backend.playable(path)` once up front to surface credential or
      reachability errors before the receiver is told to load, opens a
      `FilesCastTicket` on `FilesCastBridge`, and returns
      `ResolvedStream(url: ticket.mediaUrl, sessionId: ticket.sessionId, subtitleUrl: ticket.subtitleUrl)`.
    - `end(sessionId)` calls `bridge.closeSession(sessionId)`. Because
      `SessionSourceCastBinding` records `hlsSessionId: stream.sessionId`,
      `CastSessionManager` calls `endServerSession(sessionId)` when the cast
      stops, switches items, or fails to load.
  - `FilesPlaybackSession.receiverSubtitles(version)` returns a
    `CastSubtitleTrack` (with `url: ''`) for each sidecar in `version.streams`
    whose codec is `srt` or `vtt` (`.ass`/`.ssa` and bitmap codecs are
    omitted). When `ResolvedStream.subtitleUrl` is non-null,
    `SessionSourceCastBinding.resolve` fills each track's `url` with
    `stream.subtitleUrl!(track.trackId)` after `resolver.resolve` completes.
- **Progress reporting.** `FilesPlaybackSession.createProgress()` already
  returns a `LocalProgressReporter` (a `PeriodicProgressReporter` subclass), so
  `SessionSourceCastBinding.openProgress()` wraps it in
  `ReporterCastProgressSink` unchanged. Receiver positions write to
  `PlaybackProgressStore` and invalidate `SourceRules.watchedChanged`.
- **Firewall port hint.** `castErrorMessage` in `cast_actions.dart` checks
  `filesCastBridgeProvider`'s active port when `localProxyServiceProvider` is
  not the active LAN listener, so `castErrorUnreachableWithPort(port)` names
  the bridge port when a host firewall blocks the receiver.

## Errors

- **Share offline or file missing when starting a download or cast:** mapped
  from `BackendUnreachable` / `BackendNotFound` to `SourceException.unreachable`
  or `notFound`. Downloads park as `interrupted` (or fail on 404); casts show
  the unreachable toast and fall back to local playback.
- **Credentials rejected (WebDAV 401/403, SMB logon failure, lost folder grant):**
  `reportReachability` flags the account `needsReauth`, and the operation fails
  with `unauthorized`.
- **No LAN interface when starting a cast:** `FilesCastBridge.openSession`
  throws `SourceException.unreachable()`, which surfaces the unreachable cast
  toast.
- **Receiver rejects the file's codec:** Chromecast and DLNA return
  `CastFailureKind.mediaLoadFailed`. Because the route is `localBridge`,
  `CastSessionManager` does not retry with a transcode and shows
  `castErrorMediaLoadFailed` while local playback continues.

## Out of scope

- Offline downloads for `flocal` (files are already on the device).
- Downloading sidecar subtitle files alongside a downloaded video (v1 matches
  Plex, Jellyfin and Stash `Original` downloads).
- Client-side video or audio transcoding for cast receivers, or burning in
  `.ass`/`.ssa` and bitmap subtitles on Chromecast.
- Casting an offline downloaded file when its source share is unreachable.

## Testing

- **Dart unit (`test/core/sources/files/`):**
  - `files_download_test.dart`: `FilesMediaSource` lists
    `SourceCapability.downloadable` and returns non-null `as<Downloadable>()`
    for WebDAV (`w…`) and SMB (`s…`) accounts, and omits both for `flocal`;
    `downloadOptions` reports `IndexedFile.size`; `resolve` returns
    `DirectFile` with the backend's URL and headers, and maps every
    `BackendFailure` subclass to the right `SourceException` and `needsReauth`
    callback.
  - `subtitle_vtt_test.dart`: `srtToVtt` handles UTF-8 BOM, CRLF, multi-line
    cues, cue text containing timestamp-like strings, and passthrough of
    already-valid `WEBVTT`.
  - `files_cast_bridge_test.dart`: against a real loopback `HttpServer`:
    - Local `File` serving: `HEAD`, full `GET` (`200`), bounded and open-ended
      `Range` (`206` with `Content-Range`), unsatisfiable `Range` (`416`), and
      `Access-Control-Allow-Origin: *`.
    - HTTP upstream proxying (WebDAV/SMB shape): forwards `Range` and
      `Authorization` headers and streams `206` bodies.
    - Subtitle serving: `.srt` converted to `text/vtt` and `.vtt` passed
      through, with CORS headers.
    - `closeSession` invalidates the token (`404`) and closes the listener when
      the last session ends.
- **Session & cast binding (`test/presentation/screens/player/session/`):**
  - `files_playback_session_test.dart`: `features` contains
    `PlaybackFeature.cast`; `SessionSourceCastBinding` resolves a
    `CastRouteKind.localBridge` + `CastMediaKind.progressive` route for both
    Chromecast and DLNA, attaches rewritten `.srt`/`.vtt` subtitle URLs on
    Chromecast, omits `.ass` and DLNA subtitles, and revokes the bridge token
    on `endServerSession`.
- **Widget (`test/presentation/screens/sources/source_item_screen_test.dart`):**
  - `SourceItemScreen` renders the Download button for `ItemKind.video` on a
    downloadable source and hides it on `flocal`.
