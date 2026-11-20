# rqbit upload total that survives pauses

Finishes #1436. PR #1457 fixed the issue's two bugs; this covers its two
suggestions:

1. Show the uploaded amount next to the upload speed and ratio.
2. Keep the ratio and uploaded amount visible after the seeding goal is met.

## Problem

`Mydia.Downloads.Client.Rqbit.build_status/2` takes `uploaded` and `ratio`
from rqbit's `uploaded_bytes`. rqbit 9.0.1 counts that only for the current
session: it reads 0 once a torrent is paused, and starts again from 0 after a
restart. So:

- After `Mydia.Downloads.BuiltIn.SeedingPolicy` pauses a torrent that met its
  goal, the row's ratio drops to 0.00. Showing an uploaded amount would show
  the same wrong 0.
- A ratio-based goal (a tracker minimum or the operator's target) restarts
  from 0 on every pause or restart, so it can take far longer than intended
  to be met, or never be met.

qBittorrent, Transmission and rTorrent keep a lasting total and are not
affected.

## Decision

Mydia keeps its own upload total for clients whose counter is session-only,
the way `Mydia.Downloads.ObservedSeedTime` keeps seed time for clients that
report none. It lives in `Download.metadata`, so no migration.

Rejected:

- **A `downloads.uploaded_bytes` column.** Same stepping, but a migration on
  both adapters for no gain: Downloads sorting runs in memory on enriched
  rows, and nothing queries the total in SQL.
- **Persisting the counters inside rqbit.** The root fix, but Mydia would own
  a fork of rqbit's session persistence, and it would not help an external
  rqbit client.

## Design

### Adapter signal

`Mydia.Downloads.Structs.DownloadStatus` gains `uploaded_session_only?`
(default `false`). The rqbit adapter sets it to `true`. Enrichment copies it
onto `Mydia.Downloads.Structs.EnrichedDownload`. Nothing looks up a client's
type to decide; a future adapter with the same limitation sets the flag.

### `Mydia.Downloads.ObservedUpload`

The entry, in `Download.metadata`:

    "observed_upload" => %{"bytes" => 5_368_709_120, "session" => 1_073_741_824}

`bytes` is the running total. `session` is the client's live counter as last
recorded.

`step(entry, live)` is pure and returns the next entry:

| Case | `bytes` | `session` |
| --- | --- | --- |
| No entry (or one that does not parse) | `live` | `live` |
| `live >= session` | `bytes + (live - session)` | `live` |
| `live < session` (the client reset: pause or restart) | `bytes + live` | `live` |

Recording and every overlay use `step(entry, live, read_at)`, so what is
written and what is shown can never disagree. It also stamps `"seen_at"`
(full precision) whenever `bytes` or `session` change. `read_at` is when the
counter was asked for: the rqbit adapter stamps `DownloadStatus.observed_at`
just before it sends the request (so a delayed response parsed late still
dates from when it was asked for), carried as
`EnrichedDownload.live_uploaded_at`, with the pass's clock as the fallback.

DownloadMonitor passes can overlap (a cron tick and a fast follow-up), and
an older counter landing last would read as a reset and be added in full,
inflating the total. Two guards stop it:

- A counter read no later than `"seen_at"` changes nothing.
- A counter below `session` counts as a reset only when read at least 300
  seconds after `"seen_at"`. Two requests in flight together need not be
  read by rqbit in the order they were sent, so request time alone cannot
  order them; but a request that much older has long timed out (retries are
  off, and a status read takes at most two requests of 35s by default). A
  real reset is credited by a later pass while the counter is still below
  `session`. If the new session's counter passes the old one first, the reset
  reads as growth and its earlier uploads are lost: inside the window a
  reset cannot be told from an older read landing late, and crediting it
  would overcount in that case. The total errs low, never high.

On first sight the current session's bytes count in full. Unlike seed time,
which starts from 0 on purpose because no client reported it, uploaded bytes
are a fact the client reports. Uploads from sessions that ended before this
ships are lost: an undercount.

### Recording

`ObservedUpload.record(rows, now)` runs in `Mydia.Jobs.DownloadMonitor`
right after `ObservedSeedTime.record/2`, before `BuiltIn.Policies.run/2`.

- A row is recorded when `uploaded_session_only?` is true, `in_client?` is
  true and `status_as_of` is nil. A stale snapshot never steps: its counter
  is not this poll's.
- Every flagged torrent row is recorded, not only rows under a seeding goal,
  because the Downloads page shows the total for all of them.
- It writes only when the entry changed, under the same transaction
  `ObservedSeedTime` uses (`FOR UPDATE` on PostgreSQL, serialized writes on
  SQLite) with a plain `update_all`, so other metadata keys are kept and the
  Downloads page gets no broadcast per poll.
- A failing row is logged and returned unchanged. Recording never fails the
  poll.
- Each recorded row is returned with its new entry in `metadata` and its
  overlay recomputed, so the policies on the same pass see the new total.

Because the recording comes before `SeedingPolicy` in the same pass, the
policy's own pause loses nothing. A manual pause or a client restart between
two passes loses at most one interval's uploads. That undercounts, which errs
toward seeding longer.

### Overlay

`ObservedUpload.apply(row)`, for a flagged row:

- `live_uploaded` keeps the client's raw counter.
- `uploaded` becomes `total(entry, live_uploaded)`.
- `ratio` becomes `uploaded / size` (unchanged when `size` is 0 or unknown).

It runs in `Mydia.Downloads.History.enrich_download_with_torrent_status/2`,
so the Downloads page, sorting, `SeedingGoal`, `SeedingPolicy` and the
monitor all read the kept total. `record/2` steps from `live_uploaded`, never
from the overlaid `uploaded`, so nothing is counted twice.

`Mydia.Downloads.ClientRemoval.terms_met?/2` reads a fresh `DownloadStatus`
rather than an enriched row; it applies the same overlay to that status from
`download.metadata` before judging the goal.

### UI

On the Downloads page (`downloads_live/index.html.heex`), a new metric with
`id={"download-uploaded-#{download.id}"}`, title "Uploaded", icon
`hero-arrow-up-circle` and `format_file_size(download.uploaded)`. It sits
right after the upload speed on completed rows (speed, uploaded, ratio) and
in-flight torrent rows. It is hidden when the row is not in the client, whose
`0` is a placeholder rather than a measurement.

The "Seeding goal met" chip is unchanged: the ratio and uploaded metrics sit
beside it and stay correct after the pause, which is what the issue asks for.

## Testing

- `ObservedUpload` units: increase, reset, a reset to 0 while paused, first
  sight, a malformed entry, and overlapping reads that must not count as a reset.
- `record/2`: writes only changed entries; skips unflagged, stale and
  not-in-client rows; one bad row does not stop the others; other metadata
  keys survive.
- The rqbit adapter sets `uploaded_session_only?` (Bypass).
- Enrichment applies the overlay and keeps `live_uploaded`.
- `ClientRemoval.terms_met?/2` and `SeedingPolicy`: a torrent paused with a
  banked ratio of 2.0 still reads 2.0 and meets a 1.0 goal.
- LiveView: the uploaded element renders the kept total, and is absent for a
  row not in the client.

## Docs

`lib/mydia/downloads/README.md` gets a paragraph next to the observed seed
time one: the session-only counter, the metadata key, the undercount between
passes, and why first sight counts in full.
