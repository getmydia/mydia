# EDL commercial skipping

Requested in [discussion #1439](https://github.com/getmydia/mydia/discussions/1439).

## Goal

Viewers with DVR recordings already have commercial breaks marked in sidecar
`.edl` files, written by Comskip, MCEBuddy and similar tools. Mydia should read
those files and skip the breaks during playback, locally and when casting.

Success: drop `Show S01E01.edl` next to `Show S01E01.mkv`, rescan the library,
play the episode, and the commercial breaks are skipped automatically. A viewer
who seeks back into a break sees it play.

## Decisions

- **Ad removal is the use case.** Content filtering (where a cut must never be
  bypassable) is not a goal, so a player that does not understand the new
  segment type degrading to "no skip" is acceptable.
- **Sidecar `.edl` files only.** Mydia does not run Comskip or any detector of
  its own.
- **Actions 0 (cut) and 3 (commercial break) are both treated as commercial
  breaks.** Action 1 (mute) and action 2 (scene marker) are ignored.
- **Cuts are applied at playback time by seeking.** The file is never cut or
  remuxed, so the media timeline is unchanged and subtitle timing needs no
  adjustment. This answers the subtitle question raised in the discussion.
- **Breaks are stored as `media_segments` rows**, alongside intro and credits,
  not in a separate table and not read from disk per request.
- **Commercials get their own auto-skip setting, on by default.** Intro and
  credits auto-skip stays off by default, as today.

## Out of scope

Running Comskip, mute ranges, seekbar markers, writing `.edl` files from
Mydia's own detection, and showing breaks in the web UI.

## Server

### Schema

`Mydia.Library.MediaSegment` gains type `commercial` and source `edl`. EDL rows
store `confidence: 1.0`, so the resolver's `@segment_confidence_floor` (0.4)
never hides them.

Intro and credits keep "one per file per type". Commercial breaks are many per
file. One migration replaces the unique index `media_segments_media_file_id_type_index`
on `(media_file_id, type)` with a partial unique index of the same name and
columns, `WHERE type IN ('intro', 'credits')`. Both SQLite and PostgreSQL
support partial indexes, and dropping and recreating an index needs no table
rebuild on SQLite. The `unique_constraint/3` in `MediaSegment.changeset/2` keeps
its name. The migration uses a real timestamp, checked against every remote
branch for collisions.

### Detection must not delete EDL rows

`Mydia.Library.SegmentDetection` clears a season's segments with a bulk
`Repo.delete_all` before re-detecting (`segment_detection.ex`, the query on
`s.media_file_id in ^file_ids`). That query gains
`s.source in ["chapters", "fingerprint"]`, so it only clears rows detection
owns. Its per-type upsert (`Repo.get_by(MediaSegment, media_file_id:, type:)`)
only ever looks up `intro` and `credits`, so it never touches commercial rows.

### Parser: `Mydia.Library.Edl`

A pure module. `parse(binary) :: [{start_ms, end_ms}]`, sorted by start.

- Accepted line forms, matching what Kodi accepts:
  - `start end action`, with times in seconds as decimals (Comskip's output).
  - `start end action`, with times as `hh:mm:ss.sss` or `mm:ss.sss`.
  - `start end` with no action, which counts as a cut.
- Kept: actions `0` and `3`. Dropped: `1`, `2`, any other value.
- Dropped silently: blank lines, unparseable lines, and frame-number lines
  (`#1234`), which cannot be converted without the frame rate.
- Ranges with `end <= start` are dropped. Overlapping or touching ranges are
  merged.
- Never raises on input. An entirely unparseable file yields `[]`.

### Reconciler: `Mydia.Library.EdlSidecars`

Modelled on `Mydia.Subtitles.Sidecars`, and goes through `Mydia.Storage` for
every filesystem operation so S3 libraries work.

- `reconcile_all(media_files)` groups files by directory and calls
  `Storage.ls/1` once per directory.
- A media file's sidecar is `<video basename without extension>.edl` in the
  same directory, matched case-insensitively on the extension.
- Sidecar present: read it with `Storage.read_path/1`, parse, and compare the
  ranges with the file's existing `source = "edl"` rows. If they differ,
  replace them in one transaction (delete the file's `edl` rows, insert the new
  ones). If they match, write nothing.
- Sidecar absent: delete the file's `edl` rows, if any.
- Read errors are recorded in the tally and leave existing rows alone, so a
  temporary S3 failure does not wipe known breaks.
- Never creates, modifies or deletes the `.edl` file.
- Returns a tally `%{adopted, updated, reaped, errors}`.

`Mydia.Jobs.LibraryScanner` calls it immediately after `reconcile_sidecars/1`,
under the same conditions (`reconcile_sidecars?/1`) and with the same contract:
errors are logged, rescued, and never fail the scan.

### GraphQL

`:segment_type` in `lib/mydia_web/schema/enum_types.ex` gains
`value(:commercial, description: "Commercial break, from an EDL sidecar")`.
`SegmentType` in `server/crates/api/src/types/common.rs` gains `Commercial` to
keep the SDL parity gate green. The `segments` field and resolver are
unchanged.

## Player

### Model

`SegmentType` (`player/lib/domain/models/media_segment.dart`) gains
`commercial`, and `_parseType` maps `COMMERCIAL` and `commercial` to it.

Plex and Jellyfin already report commercials and the player currently drops
them as `unknown`. `plexSegments` maps Plex marker type `commercial`, and
`jellyfinSegments` maps Jellyfin segment type `Commercial`, to
`SegmentType.commercial`.

### Auto-skip per type

`SegmentSkipper.autoSkip` (one bool) becomes two:
`autoSkipIntroCredits` and `autoSkipCommercials`. `maybeAutoSkip` only asks
`SegmentSkipTracker.takeAutoSkip` about segments whose type is enabled. The
tracker's once-per-segment rule is unchanged: the first entry into a break
skips it, and seeking back into the same break plays it. Segment keys include
type, start and end, so distinct breaks never collide.

Casting already routes through `maybeAutoSkip`, so it needs no separate change.

### Setting

`SettingsService` gains `auto_skip_commercials`, defaulting to **true** when
unset, with a getter and setter matching `auto_skip_segments`. It is:

- shown in playback settings next to the existing auto-skip toggle,
- loaded by the player screen where `auto_skip_segments` is loaded today,
- added to the settings reset list,
- added to the backed-up keys in `player/lib/core/backup/backup_snapshot.dart`.

### Button

`SkipSegmentButton` gains a label for `SegmentType.commercial`:
`segmentSkipCommercial` = "Skip Ad", added to every `app_*.arb`. With
commercial auto-skip off, the button appears inside a break exactly as the
intro button does.

### Compatibility

Older server: never sends `COMMERCIAL`, so nothing changes. Older player: parses
the value as `unknown` and filters it out, which `MediaSegment.actionable`
already does.

## Testing

Server:

- `Edl` parser: seconds, timestamps, two-field lines, every action code,
  frame-number lines, garbage lines, reversed and zero-length ranges, overlap
  merging, empty input, Windows line endings.
- `EdlSidecars`: adopt, update on change, no write when unchanged, reap when
  the sidecar is removed, read error keeps rows, sidecar for a different
  basename ignored, an S3 library path through the storage seam.
- Detection regression: an `edl` row survives a season re-detection.
- Migration: two commercial rows on one file insert; a second intro on one file
  still violates the unique index. Run on both adapters.
- GraphQL: `segments` returns a `COMMERCIAL` segment.

Player:

- `MediaSegment` parses `COMMERCIAL`; Plex and Jellyfin mappings produce
  `commercial`.
- `SegmentSkipper`: with default settings commercials auto-skip and intros do
  not; with both flipped the reverse; seeking back into a spent break plays it.
- `SettingsService`: `auto_skip_commercials` defaults to true.
- `SkipSegmentButton` shows "Skip Ad" for a commercial segment.
