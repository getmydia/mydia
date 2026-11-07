# Files library for the player

## Why

Every source the player browses today is a server: Mydia, Plex, Jellyfin or
Stash. A viewer whose media sits in a folder on the device, or on a NAS that
speaks WebDAV, has nothing to point the player at unless they first run one of
those servers.

Infuse is the reference for what that should feel like. You add a share, it
scans the folders, matches files against TMDB, and from then on the share looks
like a real library: posters, seasons, episodes, watch state, Continue
Watching. Files it cannot match stay reachable as plain folders.

## Goal

A new source kind, `files`, that turns local folders (where the platform
allows) and WebDAV shares into a matched library, with:

- Matching done on the device through metadata-relay, so no Mydia server is
  needed.
- Watch state and resume positions stored on the device only.
- The filename parser shared with the Rust server (`server/`), so both read
  release names the same way. The same crate can later serve the Elixir server
  as a NIF.
- No changes to Home, detail, search or the player screen beyond the add flow,
  a Folders view and a Fix match sheet.

## Decisions

| Question | Decision |
| --- | --- |
| Folder browsing or full library | Full library, with a Folders view for what does not match |
| Protocols in v1 | Local folders where the platform allows, and WebDAV |
| Where matching runs | On the device, through metadata-relay's TMDB endpoints |
| Watch state | Local to the device |
| Shape | `SourceKind.files` as an ordinary `MediaSource`, in Dart |
| Shared code | Filename parser and match scoring move into a DB-free Rust crate used by the server and the player |

## Architecture

### Shared Rust crate: `native/mydia_media_names`

New crate with no database, async or filesystem dependency (only `regex`,
`serde`, `thiserror`).

- `parse(path, kind) -> ParsedFile`. The code in
  `server/crates/library/src/parser.rs`, `parser/episode.rs` and `names.rs`
  moves here unchanged, with its tests. `LibraryKind` (`Movies`, `Series`,
  `Mixed`) moves with it.
- `score(parsed, candidates) -> Option<Match>`. A pure function: given a parsed
  file group and the TMDB search results, it weighs normalized title
  similarity, year (exact, off by one, missing) and kind, and returns the best
  candidate with a confidence in `0.0..=1.0`. A result under the threshold is
  `None`, which means unmatched.
- `server/crates/library` depends on the new crate and re-exports `parser` and
  `names`, so no server code changes. `ranking.rs`, `scan.rs`, `walk.rs`,
  `sidecar.rs` and `ffprobe.rs` stay in the server crate.
- `player/rust/mydia_player_p2p` depends on it and exposes `parse_batch` and
  `score` over flutter_rust_bridge. The crate compiles for wasm32 as well, but
  web never calls it (see Platforms).

### Player: `player/lib/core/sources/files/`

**`FileSystemBackend`** is the protocol seam:

```dart
abstract interface class FileSystemBackend {
  Future<List<FileEntry>> list(String dir);     // name, isDir, size, mtime
  Future<FileEntry?> stat(String path);
  Future<PlayableFile> playable(String path);   // url + headers for mpv
}
```

Implementations:

- `LocalPathBackend`: plain paths on Linux, Windows and macOS (macOS keeps a
  security-scoped bookmark per root).
- `PlatformFolderBackend`: SAF tree URIs on Android, security-scoped bookmarks
  on iOS and iPadOS. Needs a small platform channel per OS for listing and for
  resolving the bookmark.
- `WebDavBackend`: `PROPFIND Depth: 1` over the existing HTTP stack, basic
  auth, credentials in `SourceSecrets` under the account. `playable` returns
  the file URL with the `Authorization` header, which mpv sends on every range
  request.

SMB, NFS, SFTP and cloud drives are future implementations of this interface.

**`FileScanner`** walks a library root through its backend, keeps video
extensions (`mkv mp4 m4v mov avi ts webm` and the rest of what mpv plays), and
notes sidecar subtitles (`.srt .ass .ssa .vtt` sharing the video's stem). It
diffs against the index by `(path, size, mtime)` and parses only new or changed
files, in batches across the FFI.

**`FileMatcher`** groups parsed files: episodes by normalized show title (and
year when present), movies by title plus year. It runs one relay search per
group (`/tmdb/movies/search` or `/tmdb/tv/search`), with at most 4 requests in
flight, and calls `score`. For each winner it fetches `/tmdb/movies/:id` or
`/tmdb/tv/shows/:id` plus `/tmdb/tv/shows/:id/:season` for each season present.
Match results are stored per group, so no group is searched twice unless it
changes.

**`FileLibraryIndex`** is one Hive box per account. It holds:

- files: path, size, mtime, parsed result, group key, sidecars;
- matched movies, shows, seasons and episodes with the TMDB fields the screens
  read (titles, overview, year, poster and backdrop paths, runtime, air dates);
- pins from Fix match, keyed by group;
- unmatched files.

The box is loaded into memory when the source opens and queried in Dart. It
sits behind an interface so it can move to SQLite if real libraries outgrow
memory.

**`FilesMediaSource`** is `SourceKind.files`. One account is either "Folders on
this device" or one WebDAV server; one `Library` is one added root folder with
its `LibraryKind`. It implements `libraries`, `browse`, `item`, `children` and
`artwork` from the index, and these capabilities:

- `watchedState`, `continueWatching`, `nextUp`, `recentlyAdded`,
  `unwatchedListing`, `searchable` (a search of the index, not of TMDB),
  `progressReporting` (into the local progress store).

Not offered: `downloadable`, `castable`, `progressSync`, `similar`,
`favorites`, `collections`, `calendar`, `trending`, `skipSegments`,
`mediaInfo`, `remoteTargets`. `artwork` returns TMDB image CDN URLs
(`image.tmdb.org`), which need no key; the cache key is
`sourceId|tmdbPath|width`.

**`FilesPlaybackSession`** is a direct-play `SourcePlaybackSession`. The
version's `fileId` is the file's index key; the session hands mpv
`backend.playable(path)` and attaches the sidecar subtitles as external tracks.
No transcoding.

### UI

- Add server gains "Folder" (on platforms that allow it) and "WebDAV". Folder
  opens the platform picker, then asks for the library kind. WebDAV asks for
  URL, user and password, lists the root, and lets the viewer pick folders and
  give each a kind.
- A "Folders" library on each files account browses unmatched files by
  directory and plays them directly.
- A "Fix match" sheet on movies, shows and unmatched files: search the relay by
  title and optional year, pick a result, and the choice is pinned. "Unmatch"
  moves the group's files to Folders.
- A scan banner on the library: "Scanning 312 of 2,040".

## Identity

Matched items are keyed by TMDB, not by path:

- `movie:<tmdbId>`, `show:<tmdbId>`, `season:<tmdbId>:<n>`,
  `episode:<tmdbId>:<season>:<episode>`.
- Every file that resolves to the same movie or episode is one of its
  `versions`.
- Unmatched files are `file:<hash of the library-relative path>`.

Watch state and resume key on the `ItemRef`, so renaming a file, moving it, or
replacing it with a better copy keeps its history. The kind prefix is carried
by `ItemRef.kind`; the strings above are the `externalId`s.

## Data flow

1. A scan runs when a library is added, when the source opens and its last
   scan is older than 6 hours, and on a manual Rescan.
2. List, filter, diff. Only new or changed files are parsed.
3. Group, then match with the relay as above. Pinned groups skip the search.
4. Write the index per group, so a scan cut short keeps what it finished.
5. A file no longer listed leaves its item; an item with no files left is
   removed. Progress for a removed item stays in the progress store, so a
   returning file picks up its history.
6. The source's query cache is invalidated per operation as groups land, so
   Home and the library fill in while the scan runs.

## Errors

- **Relay unreachable or rate limited:** files are indexed under their parsed
  title and kind, without artwork, and matching is retried on the next scan.
  Browsing and playback do not wait on it.
- **Share unreachable** (WebDAV down, drive unplugged): the source reports
  `unreachable`. The index stays browsable; playing shows "Folder
  unavailable".
- **Folder permission lost** (stale bookmark, revoked SAF grant) and **WebDAV
  401:** the account is flagged `needsReauth`, and the existing re-sign-in
  entry point becomes "Choose the folder again" or the WebDAV login form.
- **A file that fails to parse:** it lands in Folders, never in an error state.

## Platforms

| Platform | Local folders | WebDAV |
| --- | --- | --- |
| Linux, Windows | path picker | yes |
| macOS | path picker, security-scoped bookmark | yes |
| iOS, iPadOS | Files picker, security-scoped bookmark | yes |
| Android phone and tablet | SAF tree URI, played as `content://` | yes |
| Android TV | no (most devices have no document picker) | yes |
| Web | no | no |

Web filters the files source out, as it does other third-party sources.

**Verify first.** Before any other work, confirm on real devices that
media_kit plays, and seeks within, a SAF `content://` URI on Android and a
bookmark-resolved path on iOS. If `content://` does not work, Android ships
WebDAV only in v1 and the rest of this design is unchanged.

## Out of scope for v1

- SMB, NFS, SFTP, cloud drives.
- Downloads, casting, transcoding.
- Background rescans and filesystem watching.
- Syncing watch state across devices.
- Metadata from embedded tags or NFO files.

## Testing

- **Rust:** the parser tests move with the code; the server crate's tests pass
  against the re-export. `score` gets table tests built from invented titles,
  covering year off by one, missing year, a movies library rejecting episode
  candidates, and a below-threshold miss.
- **Dart unit:**
  - `FileScanner` diffing against a fake backend;
  - `FileMatcher` grouping, the 4-request cap, pins, and relay-down
    degradation against a fake relay;
  - `FileLibraryIndex` queries behind each capability;
  - `WebDavBackend` multistatus parsing from recorded XML.
- **Source contract:** `FilesMediaSource` joins the existing source tests,
  including `source_rules_test.dart` and the `SourceKeys` cases.
- **Widget:** the add flow, the Folders view, the Fix match sheet.
- **Manual:** `rclone serve webdav` against desktop and Android TV, and a local
  folder on each platform that allows one.
