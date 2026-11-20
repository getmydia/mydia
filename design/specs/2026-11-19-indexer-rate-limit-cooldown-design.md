# Indexer rate-limit cooldown

Issue: getmydia/mydia#1443. Built-in Cardigann indexers (RuTor, NoNaMe Club,
BigFANGroup) get rate-limited (HTTP 429) during automatic searches.

## Goal

Stop Mydia from repeating requests to a tracker that is pushing back. After a
429, Mydia holds off that indexer until a cooldown ends; every attempt counts
against the per-minute limit; scheduled work stops piling onto the same minute;
and logs say whether the tracker or Mydia did the limiting.

Success: no automatic search, health probe or manual search sends a request to
an indexer during its cooldown, and every rate-limit log line names its source.

## What the code does today

Read at `origin/master` `858b3742e`.

One movie add runs one query (`"Title Year"`), and the three reported trackers
each have one search path and no `requestDelay`, so one add is about one
request per tracker. The excess comes from around it:

1. **A 429 leaves no state.** `CardigannSearchEngine.validate_response/1` maps
   429 to `Error.rate_limited/1` and nothing remembers it. The next search
   sends again. `Retry-After` is ignored (Newznab and Jackett parse it in
   `Error.from_req_error/1`, but nothing reads it).
2. **Failures do not count.** `Indexers.search/3` calls
   `RateLimiter.record_request/1` only on `{:ok, _}`, so a tracker answering
   429 never uses up the default 3 searches/minute.
3. **Hourly crons share minute 0.** `MovieSearch all_monitored` (`0 * * * *`),
   `TVShowSearch` (`*/30 * * * *`) and `CardigannHealthCheck` (`0 * * * *`)
   start together. The health sweep sends a real search to every definition
   and does not go through `RateLimiter`.
4. **Two kinds of "rate limited" read alike.** Mydia's own per-minute limit
   logs "Rate limit exceeded for Cardigann indexer X, retry after Nms"; a
   tracker 429 surfaces as "Rate limit exceeded".

Also relevant: when every indexer errors, `MovieSearch` records a
`no_results` search backoff against the movie, so a rate-limited sweep pushes
movies back as if nothing existed.

## Design

### 1. Cooldown state in `Mydia.Indexers.RateLimiter`

In-memory, in the existing ETS table, keyed by indexer id. Lost on restart; the
first 429 afterwards starts a fresh cooldown.

- `cooldown_until(id) :: DateTime.t() | nil`, the end of the active cooldown.
- `record_rate_limited(id, retry_after_ms | nil) :: DateTime.t()` starts or
  escalates a cooldown and returns its end. Ladder steps: 1m, 5m, 15m, 30m,
  1h, 3h, 6h, staying at 6h. The wait is `max(ladder step, Retry-After)`, with
  `Retry-After` capped at 24h. A 429 recorded while a cooldown is already
  active does not step the ladder; the cooldown keeps the later of the two
  ends. Concurrent in-flight searches that all get a 429 therefore escalate
  once, not once each.
- `record_success(id) :: :ok` clears the cooldown, resets the ladder to its
  first step, and stores the success time.
- `last_success_at(id) :: DateTime.t() | nil`, read by the health sweep.
- The per-minute limit gains an atomic check-and-take (insert, count, back out
  over the limit, as `reserve_window/3` does) replacing the separate
  `check_rate_limit/2` then `record_request/1` pair.
- `clear_indexer/1` also clears cooldown and success state.
- Cleanup drops expired cooldown entries whose ladder has idled for 24h.

Time is wall-clock (`DateTime`) for display and monotonic for comparisons.

### 2. The gate in `Mydia.Indexers.search/3`

Applies to both clauses that carry an indexer id (`%IndexerConfig{}` and the
Cardigann config map). Prowlarr is excluded: it runs its own backoff ladder and
Mydia only reports it (README, "Prowlarr pauses indexers").

Order per call:

1. Cooling down: return
   `Error.rate_limited(msg, %{source: :cooldown, until: dt})` with no request.
2. Take a per-minute slot. At the limit: return
   `Error.rate_limited(msg, %{source: :local_limit, retry_after: ms})`.
3. Call the adapter.
4. `{:ok, _}`: `record_success/1`.
   `{:error, %Error{type: :rate_limited}}` from the adapter: tag
   `source: :tracker`, call `record_rate_limited/2` with its `retry_after`,
   and add `until` to the details.

Manual search goes through the same gate and shows the cooldown as the
indexer's status ("cooling down after HTTP 429 until 14:32"). It does not
override it: a request during a tracker's block only extends it.

### 3. `Retry-After` from Cardigann

`CardigannSearchEngine.validate_response/1` and the WASM path
(`Cardigann.Wasm.Codec`, which builds `Error.rate_limited/1` from the guest's
error) put `retry_after` (ms) in the error details when the response carries
`Retry-After`, either delta-seconds or an HTTP date. The parsing moves out of
`Error.from_req_error/1` into a shared function both use.

### 4. Rate-limit sources and logs

`Error.details.source` on every `:rate_limited` error:

| source | meaning |
|---|---|
| `:tracker` | the indexer answered HTTP 429 |
| `:cooldown` | Mydia is holding off after an earlier 429 |
| `:local_limit` | Mydia's per-minute limit for the indexer |
| `:daily_cap` | `TrackerLimits` daily query cap |

Log lines name the source, for example:

- `RuTor answered HTTP 429; pausing it until 14:32 (retry 2, Retry-After 120s)`
- `Skipping RuTor: cooling down after HTTP 429 until 14:32`
- `Skipping RuTor: Mydia's limit of 3 searches/minute reached`

`TrackerLimits.guard_query/2` adds `source: :daily_cap`.

### 5. Cardigann health sweep

`CardigannHealthCheck.check_all_enabled/0` (the cron job):

- Cron moves from `0 * * * *` to `45 * * * *`.
- Per definition, before probing:
  - Cooling down: skip; stored health status unchanged; log
    "skipped: cooling down until T".
  - `last_success_at` within the last hour: skip the request, refresh
    `last_checked_at`, record healthy. A real search that worked is stronger
    evidence than a probe.
- A probe that runs takes a per-minute slot like a search.
- A 429 from a probe calls `record_rate_limited/2` and does not increment
  `consecutive_failures`: a tracker throttling Mydia is not broken.

`test_connection/2` (the UI Test button) always runs, so a person can end a
cooldown early with a success. A 429 from it still escalates the ladder and
its result shows the next allowed time.

### 6. Search backoff

In `MovieSearch` and `TVShowSearch` (movie, episode and season paths): when
results are empty and every indexer error is `:rate_limited` (any source),
record no search backoff. Log `search.deferred` with reason
`indexers_rate_limited` and let the next cron run retry. A mix of
rate-limited and other errors, or any indexer answering with zero results,
keeps today's `no_results` backoff.

### 7. Documentation

`lib/mydia/indexers/README.md` gains a "Rate limits and cooldown" section
covering the gate order, the ladder, the sources and the health sweep rules,
next to "Tracker limits".

### 8. Request-rate visibility

Added during implementation at the maintainer's request: show how hard Mydia
hits each tracker.

- **Counted unit: HTTP requests that reach the tracker.** Every outbound path
  adds to a per-search count: built-in Cardigann requests (mirrors and later
  pages), login, FlareSolverr solves, WASM host exchanges, Newznab, Jackett,
  and the health probe's homepage GET. Prowlarr is not counted: its requests
  go to Prowlarr, not the tracker.
- **Stored** in a nullable integer column `http_requests` on
  `indexer_search_events`, so it follows the existing 14-day retention and
  day/week window.
- **Skips are not requests.** A search the gate refused records outcome
  `skipped_cooldown`, `skipped_local_limit` or `skipped_daily_cap` instead of
  `rate_limited`, and is excluded from attempts and success.
- **Admin Indexers stats row** gains Requests (window total, "peak N/min"),
  429s (tracker-sent, warning colour above 0) and Skipped. The indexer row
  shows "Cooling down until HH:MM" from `RateLimiter.cooldown_until/1`.
- **Logs:** the per-indexer completion line in `search_with_metrics` carries
  `http_requests`.

## Out of scope

- User-editable per-indexer request delays or limits.
- Persisting cooldowns across restarts or showing them on the admin page
  beyond the existing health status.
- Changing movie or TV search cadence, or the default 3 searches/minute.

## Testing

- `RateLimiter`: ladder escalation and cap; `Retry-After` longer than the step
  wins; 24h `Retry-After` cap; success resets; concurrent 429s step once;
  atomic per-minute slot under concurrency.
- `Indexers.search/3` with Bypass: 429 with `Retry-After` refuses the next
  call with no HTTP request (Bypass sees one hit); success clears; a failed
  search uses a slot; Prowlarr is never gated; each source is tagged.
- Cardigann Bypass test: `Retry-After` delta-seconds and HTTP-date parsing.
- WASM codec: `retry_after` carried through.
- Health sweep: cooling definition skipped; recent success skips the request;
  429 leaves `consecutive_failures` unchanged; Test button runs during a
  cooldown.
- `MovieSearch` and `TVShowSearch`: all-rate-limited result records no
  backoff; mixed errors still do.
- Cron table: `CardigannHealthCheck` not on minute 0.
