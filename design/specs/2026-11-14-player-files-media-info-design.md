# Media Info for Files libraries

## Why

The Media Info panel shows a file's container, size, bitrate and every
stream (codecs, resolution, HDR, audio layout, subtitle flags). Mydia fills
it with ffprobe on the server. A Files library (local folders, WebDAV, SMB,
paired devices' libraries) has no server, and `FilesMediaSource` does not
list `SourceCapability.mediaInfo`, so the panel answers "unsupported" for
every Files item.

The player already ships libmpv, which carries FFmpeg's demuxers. It can read
the same facts on the device.

## Prior art

Infuse reads file details when it scans a share and caches them, which is
what drives its resolution and HDR badges. A known complaint is that "Scan
for Changes" does not re-read a file replaced by an upgraded version, so its
details stay stale until the viewer edits that item by hand. Against Plex,
Jellyfin or Emby it shows the server's details instead.

## Goal

- `FilesMediaSource` implements `MediaInfo` for every Files backend,
  including paired devices' libraries.
- Desktop players read details for new and changed files in the background
  after each scan, so the panel is usually instant there.
- Mobile and TV players read details only when the panel opens, to spare
  battery and metered networks on large shares.
- A replaced file is read again on its own. No manual refresh.
- No Mydia server, no metadata-relay call, no change to the peer files
  protocol.

## Decisions

| Question | Decision |
| --- | --- |
| How details are read | A headless media_kit player (libmpv) opened on the file's playable URL |
| When, on desktop | A background queue after every scan, plus on demand on a cache miss |
| When, on mobile and TV | On demand, when the panel opens |
| Where results live | A separate Hive box, not the files index |
| Staleness | Cache entry carries the file's size and mtime; a mismatch is a miss |
| Paired devices' libraries | Read lazily by the viewing device; the host shares nothing new |
| A failed read | Base details with `streams: null`, not cached |

## Architecture

### `FilesMediaSource` as `MediaInfo`

`capabilities` gains `SourceCapability.mediaInfo` unconditionally, and
`as<MediaInfo>()` returns the source.

`mediaInfo(ref)` resolves the movie, episode or loose file to its indexed
files through the catalog, one entry per file (a movie held as two versions
gives two). An unknown `ref` throws `SourceException.notFound()`; a show or
season is not a file and returns an empty list.

Each entry starts from the index, with no I/O:

| `MediaFileInfo` field | From |
| --- | --- |
| `id` | the file key |
| `fileName`, `directory` | `IndexedFile.path` |
| `sizeBytes` | `IndexedFile.size` |
| `container` | the extension, lowercased |
| `externalSubtitles` | `IndexedFile.sidecars`, through `FilesCatalog.sidecarStreams` |

`ParsedName` carries no resolution or codec, so those stay null until a
probe answers. The probe result, when there is one, overrides `container`,
and adds `resolution` (from the default video stream: `2160p`, `1440p`,
`1080p`, `720p`, `480p`, else `<height>p`; when the height is not within 24
of a standard tier, the tier is inferred from the width, as the server does,
so 1920x800 reads `1080p`), `codec` (that stream's codec),
`durationSeconds`, `bitrate` and `streams`. `bitrate` is `size * 8 / duration`
from mpv's `file-size` and `duration`; the sum of the tracks' `demux-bitrate`
is only a fallback, because FFmpeg often leaves it empty for video. The index's
size covers a probe that reported no `file-size`.

### `MediaProbe`

`core/player/media_probe.dart` declares:

```dart
abstract interface class MediaProbe {
  /// Null when the file could not be opened or read within [timeout].
  Future<ProbeResult?> probe(PlayableFile playable, {Duration timeout});
}
```

`MpvMediaProbe` (native only) opens a media_kit `Player` with `vo=null` and
`ao=null`, paused and muted, on the playable's URL and headers: the same
transport playback uses, so local paths, WebDAV, SMB and peer reads all
work without new code. It waits for `track-list`, then for `video-params`
(which carries the colour and HDR fields once a frame is decoded), up to a
15 second timeout overall, reads `file-format`, `duration` and
`track-list`, and disposes the player in `finally`. A timeout after
`track-list` arrived still returns its streams, without the colour fields.
Calls are serialized: one probe at a time, process wide.

`ProbeResult` holds the container, duration, bitrate and a list of
`MediaStream`. The mapping from mpv's property JSON to `MediaStream` is a
pure function in its own file, `mpv_probe_mapping.dart`:

| `MediaStream` | mpv |
| --- | --- |
| `type` | `track-list[].type` (`video`, `audio`, `sub`) |
| `index` | `src-id` |
| `codec`, `codecLong` | `codec`, `decoder-desc` |
| `profile` | `codec-profile` |
| `language`, `title` | `lang`, `title` |
| `isDefault`, `isForced` | `default`, `forced` |
| `isHearingImpaired` | `hearing-impaired` |
| `isCommentary` | title contains "commentary", as Mydia's ffprobe mapping does |
| `width`, `height`, `frameRate` | `demux-w`, `demux-h`, `demux-fps` |
| `channels`, `channelLayout`, `sampleRate` | `demux-channel-count`, `demux-channels`, `demux-samplerate` |
| `bitrate` | `demux-bitrate` |
| `pixelFormat`, `colorSpace`, `colorTransfer`, `colorPrimaries` | `video-params` `pixelformat`, `colormatrix`, `gamma`, `primaries` (default video track only) |
| `bitDepth` | derived from `pixelformat` |
| `dolbyVisionProfile` | `dolby-vision-profile` where the bundled mpv reports it, else null |

External tracks (`external: true`) are left out of `streams`; sidecars
already reach `externalSubtitles` from the index.

Web gets no probe. Files sources do not exist there.

### `FilesMediaInfoCache`

A Hive box, `files_media_info`, opened alongside the files index boxes. Key
`<sourceId>|<fileKey>`; value the encoded `ProbeResult` plus the `size` and
`modified` of the file it was read from. A read whose size or mtime differs
from the current `IndexedFile` is a miss. Removing a Files account (or a
peer source) deletes its entries. Entries for files the scanner removed are
swept at the end of each scan.

It is kept out of `FileLibraryIndex` on purpose: lent indexes are
read-only replicas, and putting probe results there would change what the
peer files revision counts.

### `FilesProbeQueue` (desktop only)

When `FilesScanController` finishes a run (scan and match) on a platform
where `PlatformFeatures.isDesktop` is true, it hands the queue every indexed
file of that source whose cache entry is missing or stale. The queue:

- probes one file at a time through the shared `MediaProbe`;
- pauses while a playback session is active and resumes when it ends;
- drops its pending work when the source is removed, and replaces it when
  the same source scans again;
- never runs for a paired device's library.

Its progress is its own state (`filesProbeProgressProvider`, per source),
not part of `ScanState`, so a scan's `running` flag is not held open by it.
The scan banner shows a quieter "Reading file details n of m" line while it
runs; the library is fully usable throughout. "While playback is active"
means `playingSourceProvider.current != null`, checked before each probe
and polled every 5 seconds while it holds.

### On demand

`mediaInfo(ref)` on any platform: a fresh cache entry is used as is; a miss
resolves `playableForFileKey` and probes, then stores the result. The panel's
existing loading state covers the wait. A panel opened on desktop before the
queue reaches that file takes this path too; the queue then finds the entry
fresh and skips it.

## Errors

- The item is not in the index: `SourceException.notFound()`.
- `playableForFileKey` fails: the existing failure mapping applies,
  including the device-named peer faults, and the panel shows that error.
- The probe fails or times out: the entry is returned with `streams: null`
  (the model's "not captured yet") and nothing is cached, so the next open
  tries again. A queued probe that fails is not retried in that run.

## Out of scope

- Library badges (4K, HDR, Atmos) and smart groups built from probe results.
- Sharing probe results through the peer files index.
- Embedded tags or NFO files as metadata.
- Skip intro and credits, and the other capabilities a Mydia source has that
  Files lacks (favorites, collections, trending, similar, calendar, saved
  filters).

## Testing

- **Mapping unit tests:** recorded mpv `track-list` and `video-params` JSON
  to `ProbeResult`: an MKV with HEVC 10-bit and Dolby Vision, several audio
  tracks with a default and a commentary, forced and SDH subtitles, and an
  AVI missing most fields.
- **Cache:** hit, miss, stale on size change, stale on mtime change, sweep of
  removed files, clearing on account removal.
- **`FilesMediaSource` with a fake `MediaProbe`:** base fields from the
  index; probe fields override; failure and timeout give `streams: null`
  and are not cached; two versions give two entries; a peer source probes
  lazily. It joins `media_source_contract.dart` with `mediaInfo` listed.
- **`FilesProbeQueue`:** runs after a scan on desktop and never on mobile or
  TV (platform injected); one probe at a time; pauses during playback;
  skips fresh entries; never runs for a peer source.
- **Manual:** the real `MpvMediaProbe` on Linux against a local folder, an
  SMB share and `rclone serve webdav`; on Android TV, the panel opened
  lazily against SMB.
