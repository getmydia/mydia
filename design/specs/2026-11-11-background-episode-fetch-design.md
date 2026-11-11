# Background episode fetch on add

Issue: #1380, "Delay when adding a large show".

## Problem

Adding a TV show with several hundred episodes leaves the Discover card on
"Adding..." for a minute or more, and the user cannot add anything else in the
meantime.

Two things combine:

1. `Media.create_media_item/3` (`lib/mydia/media/items.ex`) calls
   `fetch_episodes_for_new_show/2` before returning. That runs
   `EpisodeSync.refresh_episodes_for_tv_show/2`, which fetches every season
   from the relay one after another and writes each episode with two lookups
   and an insert. Cost grows with season and episode count.
2. Discover, the dashboard and the show-page rails queue the add with
   `send(self(), ...)` (`MediaAddHelpers.queue_add/3`), so the add runs inside
   the LiveView process and the whole page is blocked until it returns.

Removing (1) makes (2) short enough not to matter: the remaining work is one
or two metadata calls and an insert.

## Goal

A TV add returns as soon as the `media_items` row exists. Episodes arrive in
the background. This applies to every add path, not only Discover.

Success looks like: on Discover, three long-running shows can be added back to
back with each card flipping to "Go to Show" within a couple of seconds.

## Non-goals

- Making the episode fetch itself faster (parallel season fetches, batched
  inserts). Possible later inside the job; not needed to fix the reported
  wait.
- Moving the remaining metadata fetch off the LiveView process.
- Changing movie adds. Movies have no episodes and are already fast.

## Design

### `Mydia.Jobs.EpisodeFetch`

A new Oban worker on the `:media` queue.

- Args: `media_item_id` (required), `season_monitoring` (default `"all"`),
  `search_on_add` (default `false`). Parsed into an `Args` struct, following
  `Mydia.Jobs.MetadataRefresh`.
- `unique: [period: :infinity, keys: [:media_item_id], states: [:available, :scheduled, :executing, :retryable]]`,
  so a double add or a retry cannot stack two fetches for the same show.
- `max_attempts: 3`.
- `perform/1`:
  1. Loads the media item. If it no longer exists or is not a `tv_show`,
     returns `{:discard, :not_found}`.
  2. Calls `Media.fetch_episodes_for_new_show/2` with `season_monitoring`.
     That function changes to return `{:ok, count} | {:error, reason}`
     instead of always `:ok`, so the job can retry relay failures. Its
     existing callers ignore the return value, so the change is safe.
  3. On `{:ok, count}`, records `Events.episodes_refreshed(item, count, :job,
     "episode_fetch")`. The function already exists and has no callers yet.
  4. On `{:ok, _}` with `search_on_add: true`, calls
     `Mydia.Search.maybe_queue_search(item, true)`.
  5. On `{:error, reason}`, returns `{:error, reason}` so Oban retries. After
     the last attempt the show stays in the library with no episodes. That is
     the same end state as today's logged failure, and the scheduled
     `MetadataRefresh` or a manual refresh recovers it.

A `Mydia.Jobs.EpisodeFetch.enqueue(media_item, opts)` helper wraps
`Oban.insert/1` (singular, for the uniqueness reason documented in
`Mydia.Search.queue_auto_searches/1`).

### `create_media_item/3`

The `:skip_episode_refresh` boolean is replaced by one option, `:episodes`:

| value | behaviour |
| --- | --- |
| `:background` (default) | enqueue `EpisodeFetch` after the insert |
| `:inline` | today's behaviour: fetch before returning |
| `:skip` | do nothing (scanner, enricher, demo seed, local shows) |

Every existing `skip_episode_refresh: true` caller becomes `episodes: :skip`.
This is a clean break with no alias kept for the old option. An unknown value
raises. `Mydia.Media.Add`'s `@create_opt_keys` forwards `:episodes` and a new
`:search_on_add` to the job args.

`:config` (an injected relay config) cannot travel through Oban args. When
`:config` is present and `:episodes` is not given, the default becomes
`:inline`. Production callers never pass `:config`. Tests that inject a
Bypass keep their current synchronous behaviour without extra changes.

Request approval calls `Add.from_attrs/4` inside its transaction. With the
default, the enqueue is a row insert in the same transaction, so a rolled-back
approval leaves no job behind and the relay is no longer called while the
transaction holds the write lock.

### Search-on-add ordering

`MediaAddHelpers.handle_add_media_to_library/6` and
`LibraryWrites` (GraphQL) call `Mydia.Search.maybe_queue_search/2` right after
the add. For a TV show added with `:background`, that would queue
`TVShowSearch` in `"show"` mode before any episode exists, and the search
would find nothing to look for.

`search_on_add` becomes an option of `Add.from_provider/5` and
`Add.from_attrs/4`, and `Add` owns the decision after a successful insert:
for a TV show added with `:background` the flag travels in the job args; for
movies and for TV shows added `:inline` or `:skip`, `Add` calls
`Mydia.Search.maybe_queue_search/2` itself. `MediaAddHelpers`, `LibraryWrites`
and `PageWrites.execute("media_add", ...)` stop calling `maybe_queue_search/2`
after an add, so there is one place the ordering lives.

### Callers that need episodes now

`MatchDialog.add_external/2` (Downloads, "match to a new title") adds a show
and immediately offers its episodes for selection. It passes
`episodes: :inline`. This is the only interactive caller that reads episodes
in the same request as the add.

`PageWrites.after_commit/4` exists only to run the fetch after the plugin
write transaction commits. With the background default, `execute/5` drops
`skip_episode_refresh` and `after_commit/4` for `"media_add"` goes away: the
job is enqueued inside the transaction and runs once it commits.

`ReleaseAdd` and the search page's manual add create the show and then start a
download. Import happens when the download completes, by which point the job
has normally finished. If an import does run before episodes exist, it fails
the same way an import into an unrefreshed show does today and is retried by
the import pipeline. They keep the default.

### UI

- Discover, dashboard and show-page rail flashes for a TV add say
  "%{title} has been added. Episodes are being fetched in the background."
  Movie flashes are unchanged.
- The show page (`MediaLive.Show`), for a `tv_show` with no episodes and a
  pending `EpisodeFetch` job (state available, scheduled, executing or
  retryable), renders a "Fetching episodes..." placeholder with a spinner
  where the season list goes, instead of the empty state. The job lookup is
  `EpisodeFetch.pending?/1`, run at mount and only when the show has no
  episodes.
- `MediaLive.Show` already subscribes to `events:all`. Its
  `{:event_created, event}` handler gains a branch: for
  `"media_item.episodes_refreshed"` on the current item, it reloads the media
  item and seasons and clears the placeholder. When the job fails for good,
  no event arrives and the placeholder stays until the next visit, where no
  job is pending and the page shows the normal empty state with its refresh
  button.

## Error handling

| Case | Outcome |
| --- | --- |
| Relay down during fetch | job retries (3 attempts); show stays, empty until refresh |
| Show deleted before job runs | job discards |
| Same show added twice quickly | `Add` reports already in library; job unique on id |
| Approval transaction rolls back | job row rolls back with it |
| `season_monitoring` "first"/"latest"/"future" | applied in the job after episodes land, as today |

## Testing

Oban runs with `testing: :manual, engine: false` in test, so jobs are inserted
and never executed.

- `EpisodeFetch` unit tests with Bypass via `perform_job/2`: creates episodes,
  applies each season-monitoring mode, chains `TVShowSearch` only when
  `search_on_add` is true and only after success, discards a missing item,
  returns `{:error, _}` on relay failure.
- `create_media_item/3`: default enqueues one `EpisodeFetch` (`assert_enqueued`)
  and fetches nothing; `:inline` fetches; `:skip` does neither; `:config`
  without `:episodes` stays inline; an unknown value raises.
- `Add`: a TV add with `search_on_add` enqueues `EpisodeFetch` carrying the
  flag and no `TVShowSearch`; an `:inline` TV add and a movie add enqueue
  their search directly.
- `MatchDialog.add_external/2` still returns episodes for selection.
- Request approval: a rolled-back approval leaves no `EpisodeFetch` row.
- `MediaLive.Show`: placeholder renders for an episode-less show with a
  pending job; an `episodes_refreshed` event replaces it with seasons.
- Existing tests that assert episodes after an add either already inject
  `:config` (so they stay inline) or are updated to pass `episodes: :inline`.
  The 31 files that mention `skip_episode_refresh` move to `episodes: :skip`.
