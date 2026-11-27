# Smart Space: clean up watched TV automatically

Issue: #1537 asks for a way to delete every file in a season at once, keeping
the show and its metadata, optionally unmonitoring the season, with a
confirmation showing count and size, and respecting the trash. Smart Space
generalises that: once a season (or episode) has been watched, Mydia trashes
its files after a grace period and stops monitoring it, so a library of shows
in progress does not grow without bound.

The manual "Delete season files" action from #1537 ships as part of this work.
It is the primitive the automation calls.

## Goals

- Free disk space from TV the household has finished, without anyone having
  to remember to do it.
- Never surprise anyone: off by default, a preview of everything that will be
  removed, a one-click "Keep", and everything recoverable from the trash.
- A manual "Delete season files" action on every season (#1537).

## Non-goals

- Movies. The rule model leaves room for them; nothing here builds it.
- GraphQL and the Flutter player. The web UI is the primary interface.
- Disk-pressure triggers ("clean up when free space drops below X").
- Permanent deletion by the automation. It only ever trashes.

## Rule model

### Global rule

A new `smart_space` embed in `Mydia.Config.Schema`, layered yaml -> db -> env
like every other section:

| field            | type            | default         | meaning |
| ---------------- | --------------- | --------------- | ------- |
| `enabled`        | boolean         | `false`         | Master switch for the global rule. |
| `unit`           | string enum     | `"season"`      | `"season"` or `"episode"`. |
| `grace_days`     | integer >= 0    | `7`             | Days between "watched" and "trashed". |
| `watched_by`     | string enum     | `"all_started"` | `"all_started"`, `"any"` or `"selected"`. |
| `selected_users` | list of strings | `[]`            | Usernames; read only when `watched_by` is `"selected"`. |

Usernames rather than user IDs so the list can be written in yaml or env.
Enum-valued env vars get a dedicated fixed-value parser that maps unknown
strings to `:invalid`, following `parse_external_torrents/1`, never
`Loader.parse_atom/1` (see `lib/mydia/config/README.md`). Config validation
rejects invalid enums, a negative `grace_days`, and a `"selected"` policy
with an empty list. Whether the usernames exist is not a config validation:
it is checked when the job loads its inputs and when the settings card saves.
Config rows for `smart_space.*` are stored under category `:general`.

The watched policy is global only. Whose viewing counts is a household
decision, not a per-show one.

### Per-show override

New table `smart_space_overrides`:

| column          | type                         | notes |
| --------------- | ---------------------------- | ----- |
| `id`            | binary id                    | |
| `media_item_id` | references `media_items`     | unique, `on_delete: :delete_all` |
| `mode`          | text                         | `"inherit"`, `"off"` or `"custom"` |
| `unit`          | text, nullable               | required when `mode` is `"custom"` |
| `grace_days`    | integer, nullable            | required when `mode` is `"custom"` |
| timestamps      |                              | |

A show without a row inherits. `"custom"` applies even when the global rule
is disabled, so one show can opt in on its own. `"off"` exempts a show even
when the global rule is enabled. Only TV media items may have a row.

### Keeps

New table `smart_space_keeps`:

| column          | type                         | notes |
| --------------- | ---------------------------- | ----- |
| `id`            | binary id                    | |
| `media_item_id` | references `media_items`     | `on_delete: :delete_all` |
| `season_number` | integer, nullable            | |
| `episode_id`    | references `episodes`, nullable | `on_delete: :delete_all` |
| `created_by_id` | references `users`, nullable | `on_delete: :nilify_all` |
| `inserted_at`   | utc_datetime                 | |

Exactly one level per row: show (both nullable columns null), season
(`season_number` set) or episode (`episode_id` set). A changeset check
enforces that `season_number` and `episode_id` are not both set; a unique
index per level prevents duplicates. A keep lasts until someone removes it. `Rules.keep` rejects non-TV items,
episodes that belong to another show, and seasons with no episodes; a
malformed keep row counts as a show keep.

### Fixed behaviour

Not configurable:

- The action is always "move to trash" (`Library` trash path, `reason:
  :smart_space`) followed by unmonitoring the affected episodes.
  `:smart_space` is a new value on `MediaFile.trashed_reason`'s
  `Ecto.Enum`; the column is `:text`, so no migration is needed for it.
- Season 0 (specials) is never eligible.
- A season is complete only when every episode has aired and every aired
  episode that has files is watched. An aired episode with no files holds the
  season while it is still monitored: it is wanted and not yet downloaded, so
  the season is not done. Only file-less episodes that are already
  unmonitored are skipped. Unaired means `air_date` is nil or after today,
  where today is the date of the evaluation instant. Unaired episodes keep a
  season ineligible under the season unit.
- Restoring a file that Smart Space trashed (`trashed_reason: :smart_space`)
  creates an episode keep for its episode, so the next run does not trash it
  again. Under the season unit that keep holds the whole season. The keep is
  made in `Library.restore_media_file/1`, which every restore path uses (the
  trash page, the bulk restore job, the scanner). Restoring a file trashed for
  any other reason creates no keep.
- Episodes with an in-flight download are skipped. "In flight" means a
  `Download.occupying/1` row: an episode download marks that episode, and a
  season-pack download (`episode_id` nil) marks the whole show. Import
  candidates carry no episode link, so they are not part of this check.
- Extras (files with `extra_kind` set) are neither counted nor trashed by the
  automation.

Migrations use `:text` for strings, a real timestamp, and a check of every
remote branch for version collisions before the filename is final.

## Eligibility

### The evaluator

`Mydia.SmartSpace.Evaluator.eligible(inputs, now) :: [Cleanup.t()]` is a
pure function: no Repo, no config reads, no clock. Inputs are plain structs:

- the global rule and each show's override,
- each show's episodes: id, season, episode number, air date, whether it is
  monitored, live (not trashed) file ids and sizes, an "in flight" flag for
  downloads or imports,
- the keeps,
- per-user watch records: `user_id`, `episode_id`, `watched`,
  `last_watched_at`, from `playback_progress`,
- the resolved selected user ids, or `:misconfigured`.

Output, one `%Mydia.SmartSpace.Cleanup{}` per unit to remove:
`media_item_id`, `season_number`, `episode_ids`, `file_ids`, `bytes`,
`eligible_at`.

### Effective rule

Override `"custom"` -> its unit and grace; `"off"` -> skip the show;
`"inherit"` or no row -> the global rule if enabled, otherwise skip.

### Who must have watched

For a show, the required users are:

- `all_started`: every user with at least one `playback_progress` row on any
  episode of the show. No such user means nothing in the show is eligible.
- `any`: none in particular; an episode is done when at least one user has
  `watched: true` on it.
- `selected`: every selected user, whether or not they have started the show.
  A selected user who never starts it blocks it; naming someone means "wait
  for them".

`:misconfigured` (a selected username that does not resolve) makes the
evaluator return no cleanups at all. Usernames are resolved when the job
loads its inputs; an unknown name means misconfigured, nothing is trashed and
one warning event is written. When nothing is in scope (no rule enabled
anywhere), the job does nothing and writes no event, even if `selected_users`
is stale.

An episode is **done** when every required user has `watched: true` on it
(or, under `any`, at least one user has).

### The grace clock

- Episode unit: `done_at` is the latest `last_watched_at` among the required
  users' records on that episode (under `any`, the earliest watched record,
  since one watcher is enough). The same holds for `done_at` under the `any`
  policy at season level.
- Season unit: the season must have every episode aired, no monitored
  episode without files, and every aired episode with files done; `done_at`
  is the latest episode `done_at` in it.
  A season cleanup lists every episode of the season for unmonitoring, but its
  `file_ids` are only the approved non-extra files.
- `eligible_at = done_at + grace_days`. A unit is returned when
  `eligible_at <= now`.

A rewatch moves `last_watched_at` forward and so extends the grace period.

### Exclusions

After computing candidates, drop any unit that is season 0, covered by a keep
at its own level or above, has no live files, or contains an in-flight
episode. Under the season unit, one in-flight episode holds the whole season
back.

### Loader

`Mydia.SmartSpace.Loader.load(opts)` builds the evaluator's inputs in a fixed
number of batched queries: shows with an effective rule (global enabled, or
an override row with `"custom"`), their episodes and live files, keeps,
watch records, and in-flight markers. It resolves `selected_users` to ids.
`opts[:media_item_id]` narrows it to one show for the show page.

## Acting on it

### Shared primitive

`Mydia.Library.trash_episode_files(episode_ids, opts)` trashes every live
media file on the given episodes, including additional versions, by calling
the existing `trash_media_file/2` per file with `opts[:reason]`. The manual
season dialog uses it and so trashes all live files of the season's episodes.
The job instead trashes exactly the evaluator's `file_ids` through
`Library.trash_media_files/2`. It never
stops on a failure: it returns `{:ok, %{trashed: [file], failed: [{file,
reason}], bytes: n}}`. A sibling `delete_episode_files(episode_ids, opts)`
covers the manual dialog's other two modes (`delete_files: true | false`).

### The job

`Mydia.Jobs.SmartSpaceCleanup`, an Oban cron job, daily, unique per period.

1. Return early when no global rule is enabled and no `"custom"` override
   exists.
2. Load, evaluate with `DateTime.utc_now()`.
3. If the rule is misconfigured, write one warning event and stop.
4. Take cleanups in `eligible_at` order up to a cap of 200 files per run. A
   cleanup that would push the run over 200 files is skipped and logged once
   per run; later, smaller cleanups may still be taken.
5. For each cleanup: `Library.trash_media_files(file_ids, reason:
   :smart_space)`, then `Mydia.Media.Monitoring.set_episodes_monitored/2`
   with `false` for the episodes whose files all trashed. Episodes with a
   failed file stay monitored.
6. Write one `Mydia.Events` entry per cleanup with show, season or episode,
   file count and bytes.

Re-running is safe: trashed files are no longer live, so the evaluator stops
returning them. A file that failed is still live and eligible, so the next
run retries it.

### Preview

`Mydia.SmartSpace.upcoming(within_days \\ 30)` runs the same Loader and
Evaluator with `now + within_days` for the grace clock, returning cleanups
with their `eligible_at`. Airing is still judged against today, not the
future date, so a season whose last episode has not aired yet is never
previewed as due (it could not be trashed at that run). The preview and the
job share code, so they cannot disagree.

## UI

### Settings

A Smart Space card in the media section of `AdminSettingsLive`, using the
existing config row plus modal pattern: enabled, unit, grace days,
watched-by, and a user multi-select (daisyUI `filter` chip row) for
`"selected"`. Values pinned by yaml or env show their source and are
read-only, as for other layered settings.

### `/smart-space`

New admin page `AdminSmartSpaceLive.Index`, linked in the nav beside Trash.

- Header: total bytes due in the next 30 days, last run time.
- "Upcoming" tab: a stream of cleanups (show, "Season N" or episode, file
  count, size, "in N days" or "next run"), each with a **Keep** button that
  writes a keep at that level and refreshes the stream.
- "Kept" tab: current keeps with **Remove**.
- Empty state: nothing scheduled, with a link to settings when Smart Space is
  off everywhere.

### Show page (`MediaLive.Show`)

- Monitoring menu entry: "Smart Space: Inherit (season, 7 days)", "Off",
  "Custom...". Custom opens a page-level modal (same reasoning as the quality
  profile picker: the hero column clips anchored dropdowns) for unit and
  grace days.
- Season header action group gains **Delete season files**
  (`season-N-delete-files`), shown when the season has files and the user can
  delete media. Its dialog shows "Season N: X files, Y GB", the three modes
  from the per-file dialog (library only, trash, permanent; trash selected),
  and "Stop monitoring this season", checked by default. The radio group is
  extracted from `Modals.file_delete_confirm_modal/1` into a shared component
  so both dialogs use one copy. Authorized with `authorize_delete_media`.
- When Smart Space applies to the show, each season header shows a "Cleans up
  in N days" badge (from the show-scoped preview) and a **Keep** toggle;
  under the episode unit, episode rows get the toggle instead.

### Trash page

The reason column renders `:smart_space` as "Smart Space". Restoring such a
file keeps its episode from being cleaned up again but does not re-monitor
it; the page says so for this reason.

All new strings go through gettext. New interactive elements get stable DOM
IDs.

## Failure handling

| failure | behaviour |
| ------- | --------- |
| One file cannot be trashed (permissions, `{:trash_move_failed, _}`) | Logged; its episode stays monitored; the rest of the cleanup continues; retried next run. |
| Misconfigured rule reaches runtime via yaml or env | No deletions; one warning event per run. |
| Job crashes mid-run | Completed cleanups stand; Oban retries; re-evaluation skips what is already trashed. |
| A rule broader than intended | At most 200 files per run, and every file is in the trash for `trash_retention_days`. |

## Testing

- **Evaluator**, table-driven and database-free: each `watched_by` policy;
  both units; grace exactly at the boundary and one second past it; a rewatch
  extending grace; an aired-incomplete season; an unaired episode; season 0;
  keeps at show, season and episode level; an in-flight episode under each
  unit; a selected user who never started; nobody started under
  `all_started`; override `"custom"` with global off; override `"off"` with
  global on; `:misconfigured`.
- **Loader**: inputs built correctly from real rows, including trashed files
  excluded and multiple versions included. Runs on SQLite and the Postgres
  CI lane.
- **`trash_episode_files` / `delete_episode_files`**: every mode, other
  seasons untouched, episode rows kept, partial failure reported.
- **Job**: end to end on fictional shows; trashes with `reason:
  :smart_space`, unmonitors, writes events, honours the cap, does nothing when
  disabled, one failing file does not block the rest.
- **Config**: enum parsing of env values, validation of `selected_users`.
- **LiveView**: season delete dialog (count, size, modes, unmonitor
  checkbox), `/smart-space` list and Keep, settings card save, show-page
  override and season Keep toggle, by element ID.
- Migrations are covered by the existing no-varchar test.
