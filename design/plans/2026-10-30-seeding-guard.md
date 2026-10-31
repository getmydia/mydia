# Seeding guard and client limits: implementation plan

Spec: `design/specs/2026-10-30-private-trackers-roadmap-design.md`, "Spec 1:
Seeding guard and client limits". Builds on Spec 0 (tracker terms frozen in
`Download.metadata["tracker_terms"]`, `minimum_seed_time` in seconds there).

**Goal:** no automatic client removal before a tracker's seeding goal is met,
on any torrent client; per-torrent limits pushed to qBittorrent and
Transmission at grab; the goal visible in the Downloads list and in the manual
removal confirm.

**Architecture:** the rule lives in a new pure module,
`Mydia.Downloads.SeedingGoal`. `ClientRemoval` gains `terms_met?/2` and runs it
ahead of its state check. Limits are a new optional adapter callback,
`set_share_limits/3`, called through `Client.set_share_limits/4` (the
`list_files` pattern) by a small `Mydia.Downloads.SeedingLimits` module at
grab. The UI reads `SeedingGoal.for_download/2` off the enriched row through a
shared `MydiaWeb.SeedingComponents`.

## Files

| File | Change |
|---|---|
| `lib/mydia/downloads/seeding_goal.ex` | New: terms from metadata, `applies?/1`, `met?/3`, `seeding_time/5`, `for_download/2` |
| `lib/mydia/downloads/client_removal.ex` | `terms_met?/2`; both removal paths flattened into one `remove_when_ready/3` |
| `lib/mydia/jobs/media_import.ex` | Handle `:still_seeding` from `maybe_remove_after_import/1` |
| `lib/mydia/downloads/structs/download_status.ex` | `seeding_time` field |
| `lib/mydia/downloads/structs/enriched_download.ex`, `history.ex` | Carry `seeding_time` to the UI (history.ex is over the size cap: net zero lines) |
| `lib/mydia/downloads/client.ex` | Optional `set_share_limits/3` callback and facade |
| `lib/mydia/downloads/client/qbittorrent.ex` | `seeding_time` parsing, `setShareLimits` |
| `lib/mydia/downloads/client/transmission.ex` | `secondsSeeding` field, `torrent-set` with `seedRatioLimit` and `seedRatioMode=1` |
| `lib/mydia/downloads/seeding_limits.ex` | New: best-effort push at grab |
| `lib/mydia/downloads/queue/client_selection.ex` | Push limits after a successful add |
| `lib/mydia_web/components/seeding_components.ex` | New: seeding chip and removal warning text |
| `lib/mydia_web/live/downloads_live/list_components.ex`, `index.html.heex` | Chip in rows, warning in cancel/clear confirms |
| `lib/mydia_web/live/media_live/show/modals.ex` | Warning in the cancel-download modal (over the size cap: net zero lines) |
| `lib/mydia_web/live/admin_download_clients_live/components.ex` | Note on which clients receive limits |
| `lib/mydia/downloads/client/ADAPTER_GUIDE.md`, `lib/mydia/downloads/README.md` | Docs |

## Task 1: SeedingGoal and terms_met?/2

- [ ] Test `test/mydia/downloads/seeding_goal_test.exs`, truth table for
  `met?/3`: ratio only (below, at), time only (below, at), both (either one
  suffices), neither and not private (met), private without ratio or time
  (never met), nil terms (met). `seeding_time/5` precedence: reported, then
  client `completed_at`, then download `completed_at`, then nil.
- [ ] Tests in `client_removal_test.exs`: guarded qBittorrent row paused but
  under ratio returns `:still_seeding` from both paths and removes nothing;
  unguarded unchanged; private without terms never removed; rqbit with terms
  not met is kept (`:still_seeding`), and removed once met; rqbit without
  terms still removed without a status call.
- [ ] Implement. Guard applies to every client type except the non-seeding
  ones (SABnzbd, NZBGet, debrid), which have no ratio to wait for.
- [ ] `media_import.ex`: `:still_seeding` logs and keeps the row pending.
- [ ] Commit `feat(downloads): keep torrents until the tracker's seeding goal is met`.

## Task 2: seeding_time on DownloadStatus

- [ ] Bypass tests: qBittorrent `seeding_time` and Transmission
  `secondsSeeding` land in `DownloadStatus.seeding_time`.
- [ ] Add the field; request `secondsSeeding` in both Transmission field lists.
- [ ] Carry it on `EnrichedDownload`.
- [ ] Commit `feat(downloads): read seeding time from qBittorrent and Transmission`.

## Task 3: pushed limits

- [ ] Bypass tests: qBittorrent posts `hashes`, `ratioLimit`,
  `seedingTimeLimit` (minutes, rounded up), `inactiveSeedingTimeLimit=-2`, with
  `-1` for an unset limit; Transmission posts `torrent-set` with
  `seedRatioLimit` and `seedRatioMode: 1`, and sends nothing without a ratio.
- [ ] `SeedingLimits.push/4` tests with stub adapters: skipped without
  ratio/time, `:unsupported` for adapters without the callback, error logged
  and returned without raising. Grab test: a qBittorrent stub sees the limits.
- [ ] Implement callback, facade, adapters, push, call site.
- [ ] ADAPTER_GUIDE section on optional callbacks.
- [ ] Commit `feat(downloads): push tracker share limits to qBittorrent and Transmission`.

## Task 4: UI

- [ ] LiveView tests: a guarded row shows `#download-seeding-<id>` with the
  progress text; a met row says "Seeding goal met"; the cancel and clear
  buttons' `data-confirm` name the tracker and say hit-and-run; an unguarded
  row has neither. Media page cancel modal shows `#seeding-removal-warning`.
  Admin clients page has `#download-clients-seeding-note`.
- [ ] Implement, `mix gettext.extract --merge`.
- [ ] Commit `feat(downloads): show seeding goals and warn before a hit-and-run`.

## Task 5: docs

- [ ] `lib/mydia/downloads/README.md` "Seeding guard" section; spec section
  updated with deviations.
- [ ] Commit `docs(downloads): seeding guard and share limits`.
